// MockURLProtocol.swift
// PopGuyTests/Mocks
//
// A URLProtocol subclass that intercepts requests and returns canned HTTP responses.
// Inject via URLSessionConfiguration.protocolClasses to keep tests fully offline.
//
// Usage:
//   MockURLProtocol.register(host: "api.openai.com") { _ in
//       return (.init(statusCode: 200, headers: ["Content-Type": "text/event-stream"]),
//               Data("data: hello\n\ndata: [DONE]\n\n".utf8))
//   }
//   let config = URLSessionConfiguration.ephemeral
//   config.protocolClasses = [MockURLProtocol.self]
//   let session = URLSession(configuration: config)
//
// Thread-safety: the handler registry is protected by an NSLock so sibling
// test suites running on different hosts can register concurrently without
// data races. Each suite is also annotated @Suite(.serialized) so tests
// within the SAME suite (sharing the same host key) never run in parallel.
//
// Cross-suite isolation: concurrent suites dispatch to distinct host keys →
// no cross-suite handler bleed even when suites run in parallel.

import Foundation

// MARK: - Response model

struct MockHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]

    init(statusCode: Int = 200, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = headers
    }
}

// MARK: - Handler registry

/// Thread-safe host-keyed handler registry backing MockURLProtocol.
///
/// @unchecked Sendable is justified: all mutable access to `_registry` is
/// serialised by `lock`. The lock is itself a value-type-safe NSLock held
/// as a constant reference.
final class MockHandlerRegistry: @unchecked Sendable {

    static let shared = MockHandlerRegistry()

    private let lock = NSLock()
    // Key = request URL host (e.g. "api.openai.com")
    private var _registry: [String: @Sendable (URLRequest) throws -> (MockHTTPResponse, Data)] = [:]

    private init() {}

    /// Register a handler for all requests whose URL host equals `host`.
    func register(host: String, handler: @escaping @Sendable (URLRequest) throws -> (MockHTTPResponse, Data)) {
        lock.withLock { _registry[host] = handler }
    }

    /// Remove the handler for `host`.
    func unregister(host: String) {
        lock.withLock { _registry.removeValue(forKey: host) }
    }

    /// Look up a handler by request host. Returns `nil` when no handler is registered.
    func handler(for request: URLRequest) -> (@Sendable (URLRequest) throws -> (MockHTTPResponse, Data))? {
        guard let host = request.url?.host else { return nil }
        return lock.withLock { _registry[host] }
    }
}

// MARK: - MockURLProtocol

final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    // MARK: - Convenience registration

    /// Register a response handler keyed by the URL host.
    /// Tests call this once per suite / per test that needs a non-default response.
    static func register(host: String, handler: @escaping @Sendable (URLRequest) throws -> (MockHTTPResponse, Data)) {
        MockHandlerRegistry.shared.register(host: host, handler: handler)
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockHandlerRegistry.shared.handler(for: request) else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "MockURLProtocol", code: -1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "No handler registered for host: \(request.url?.host ?? "<nil>")"]))
            return
        }

        do {
            let (mockResponse, body) = try handler(request)

            // Build the HTTP response.
            var allHeaders: [String: String] = ["Content-Type": "text/event-stream"]
            for (k, v) in mockResponse.headers { allHeaders[k] = v }

            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: mockResponse.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: allHeaders
            )!

            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)

        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
