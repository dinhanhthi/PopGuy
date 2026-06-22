// SSEDecoder.swift
// PopGuy — ProviderLayer
//
// Decodes a raw Server-Sent Events byte stream into an AsyncThrowingStream of
// data-line payloads (the text after the "data: " prefix).
//
// Design:
//   - Each adapter owns its own JSON parsing of the data payload; this decoder
//     is deliberately neutral — it does NOT parse choices[].delta or
//     content_block_delta. That keeps it reusable across OpenAI, Anthropic,
//     Ollama, etc.
//   - The OpenAI `data: [DONE]` sentinel is consumed silently (not emitted).
//   - Non-data lines (event:, id:, retry:, comments) are skipped.
//   - Stream terminates when the HTTP body ends or on a thrown error.

import Foundation

/// Decodes Server-Sent Events from an `AsyncBytes` stream.
///
/// Thread-safety: each call to `decode` creates an independent stream with its
/// own `Task`. The struct itself has no mutable state — all work is in the
/// task closure.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target)
// so SSE line iteration runs on an arbitrary executor, not the main thread.
nonisolated struct SSEDecoder: Sendable {

    /// Decode SSE lines from `bytes`.
    ///
    /// - Parameter lines: The async line sequence from a URLSession AsyncBytes response.
    /// - Returns: `AsyncThrowingStream<String, Error>` emitting the payload of
    ///            each `data: <payload>` line. `[DONE]` is consumed silently.
    func decode(lines: AsyncLineSequence<URLSession.AsyncBytes>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        if Task.isCancelled { break }
                        if line.hasPrefix("data:") {
                            // SSE spec: "data:<payload>" and "data: <payload>" are both valid.
                            // Drop the "data:" prefix then strip AT MOST ONE leading space
                            // (per spec a single space after the colon is ignored).
                            var payload = String(line.dropFirst(5)) // drop "data:"
                            if payload.hasPrefix(" ") { payload.removeFirst() }
                            // Silently consume the OpenAI termination sentinel.
                            if payload == "[DONE]" { break }
                            continuation.yield(payload)
                        }
                        // event:, id:, retry:, comment lines — skip silently.
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancel the upstream URLSession.bytes task when the consumer terminates
            // (cancelled or finished). Prevents continued network drain + token billing.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
