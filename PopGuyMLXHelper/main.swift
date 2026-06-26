// main.swift
// PopGuyMLXHelper
//
// Entry point for the PopGuyMLXHelper stdio CLI process.
// Reads JSON-lines from stdin (one HelperRequest per line), dispatches to ModelRunner,
// and writes JSON-lines to stdout (HelperResponse lines).
//
// Stdin reading (byte-bounded):
//   - Bytes are accumulated in a Data buffer, splitting on 0x0A (newline).
//   - The 8 MB cap is enforced DURING accumulation: if the current line buffer exceeds
//     kMaxLineLengthBytes before a newline arrives, the overflow bytes are discarded until
//     the next newline and an error response is emitted — without ever allocating the full
//     oversize payload.
//   - Blank lines are skipped silently.
//   - Bad JSON decodes emit an error response and continue the loop.
//   - EOF triggers a clean exit.
//
// Architecture:
//   - A detached background Task reads stdin bytes and feeds StdinLine values into an
//     AsyncStream channel. This keeps the @MainActor dispatch loop non-blocking.
//   - A detached watchdog Task monitors idle time and unloads the model after 5 minutes
//     of inactivity, freeing GPU memory.
//   - ActivityTracker actor provides thread-safe idle time tracking.

import Foundation

// MARK: - Constants

/// Maximum line length in bytes before the line is rejected (OOM prevention).
/// The cap is enforced during accumulation — no oversize buffer is ever allocated.
private let kMaxLineLengthBytes = 8 * 1024 * 1024  // 8 MB
private let kIdleTimeoutSeconds: TimeInterval = 300  // 5 minutes
private let kWatchdogIntervalSeconds: TimeInterval = 30

// MARK: - ActivityTracker

/// Thread-safe idle time tracker for the watchdog.
private actor ActivityTracker {
    private var lastActivity: Date = Date()

    func touch() {
        lastActivity = Date()
    }

    func idleSeconds() -> TimeInterval {
        Date().timeIntervalSince(lastActivity)
    }
}

// MARK: - StdinLine

/// Lines received from stdin.
private enum StdinLine: Sendable {
    /// A complete line within the byte cap.
    case line(String)
    /// A line that exceeded kMaxLineLengthBytes (content discarded).
    case oversized
    /// stdin reached EOF.
    case eof
}

// MARK: - Output

private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = []
    return e
}()

private func writeResponse(_ response: HelperResponse) {
    guard let data = try? encoder.encode(response),
          let json = String(data: data, encoding: .utf8) else { return }
    print(json)
    fflush(stdout)
}

// MARK: - Byte-bounded stdin reader

/// Reads stdin in chunks, accumulating bytes into a line buffer and splitting on 0x0A.
/// Enforces kMaxLineLengthBytes during accumulation: overflowed lines are discarded
/// byte-by-byte until the next newline — no oversize buffer is ever allocated.
private func readStdinLines(into continuation: AsyncStream<StdinLine>.Continuation) {
    let handle = FileHandle.standardInput
    var lineBuffer = Data()
    lineBuffer.reserveCapacity(4096)
    var overflowed = false  // true when the current line has exceeded the cap

    while true {
        // availableData blocks until bytes arrive or EOF.
        let chunk = handle.availableData
        if chunk.isEmpty {
            // EOF: flush any unterminated line then signal end.
            if overflowed {
                continuation.yield(.oversized)
            } else if !lineBuffer.isEmpty {
                if let str = String(data: lineBuffer, encoding: .utf8) {
                    continuation.yield(.line(str))
                } else {
                    continuation.yield(.oversized)
                }
            }
            continuation.yield(.eof)
            continuation.finish()
            return
        }

        for byte in chunk {
            if byte == 0x0A {
                // Newline: complete the current line.
                if overflowed {
                    continuation.yield(.oversized)
                } else if !lineBuffer.isEmpty {
                    if let str = String(data: lineBuffer, encoding: .utf8) {
                        continuation.yield(.line(str))
                    } else {
                        continuation.yield(.oversized)
                    }
                }
                // else blank line — skip silently
                lineBuffer.removeAll(keepingCapacity: true)
                overflowed = false
            } else if overflowed {
                // Already overflowed — discard bytes until the next newline.
                continue
            } else {
                lineBuffer.append(byte)
                if lineBuffer.count > kMaxLineLengthBytes {
                    overflowed = true
                    lineBuffer.removeAll(keepingCapacity: false)
                }
            }
        }
    }
}

// MARK: - Main

@MainActor
func runMain() async {
    let runner = ModelRunner()
    let activity = ActivityTracker()
    let decoder = JSONDecoder()

    // Channel: background stdin reader → main actor dispatch loop.
    let (lineStream, lineContinuation) = AsyncStream<StdinLine>.makeStream()

    // Watchdog: unload model after sustained inactivity.
    let watchdog = Task.detached {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(kWatchdogIntervalSeconds * 1_000_000_000))
            let idle = await activity.idleSeconds()
            if idle >= kIdleTimeoutSeconds {
                await runner.unload()
            }
        }
    }

    // Stdin reader: runs on a background thread so the blocking byte loop does not block @MainActor.
    let stdinReader = Task.detached {
        readStdinLines(into: lineContinuation)
    }

    // Emit startup ready signal.
    writeResponse(.ready)

    // Dispatch loop: process one request at a time on @MainActor.
    for await stdinLine in lineStream {
        switch stdinLine {
        case .eof:
            watchdog.cancel()
            stdinReader.cancel()
            return

        case .oversized:
            writeResponse(.error(message: "Request line exceeds \(kMaxLineLengthBytes / 1024 / 1024) MB limit."))
            await activity.touch()

        case .line(let raw):
            await activity.touch()

            guard let data = raw.data(using: .utf8),
                  let request = try? decoder.decode(HelperRequest.self, from: data) else {
                writeResponse(.error(message: "Failed to decode request JSON."))
                continue
            }

            switch request {
            case .ping:
                writeResponse(.ready)

            case .unload:
                await runner.unload()
                writeResponse(.done)

            case .download(let modelID):
                let modelDownloader = ModelDownloader(hubClient: sharedHubClient)
                do {
                    _ = try await modelDownloader.downloadSnapshot(
                        modelID: modelID,
                        progressHandler: { progress in
                            // Use fractionCompleted to aggregate child file progress.
                            // progress.completedUnitCount stays 0 on the parent; only
                            // fractionCompleted correctly reflects child progress.
                            let fraction = max(0.0, min(1.0, progress.fractionCompleted))
                            let total = progress.totalUnitCount
                            let downloaded = Int64(Double(total) * fraction)
                            writeResponse(.progress(
                                modelID: modelID,
                                fraction: fraction,
                                downloadedBytes: downloaded,
                                totalBytes: total
                            ))
                        }
                    )
                    writeResponse(.done)
                } catch {
                    writeResponse(.error(message: error.localizedDescription))
                }

            case .generate(let modelID, let systemPrompt, let input, let maxTokens, let temperature):
                let stream = await runner.generate(
                    modelID: modelID,
                    systemPrompt: systemPrompt,
                    input: input,
                    maxTokens: maxTokens,
                    temperature: temperature
                )
                do {
                    for try await delta in stream {
                        writeResponse(.token(delta: delta))
                        await activity.touch()
                    }
                    writeResponse(.done)
                } catch {
                    writeResponse(.error(message: error.localizedDescription))
                }
            }
        }
    }

    watchdog.cancel()
    stdinReader.cancel()
}

// Swift CLI entry point: run the async main on the main actor.
await runMain()
