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

// MARK: - Download progress state

/// Shared mutable state for the two concurrent progress paths during a Xet download.
///
/// @MainActor isolation makes this implicitly Sendable without @unchecked.
/// Both the progressHandler (already @MainActor) and the disk-polling sampler
/// (Task { @MainActor in ... }) access it on the same actor, so no data races.
@MainActor
private final class DownloadProgressState {
    /// Total byte count captured from the first Progress callback.
    /// Set to progress.totalUnitCount on the first call where it is > 0.
    var expectedTotal: Int64 = 0
    /// Monotonically increasing best-known fraction. Never goes backwards.
    var highWater: Double = 0
}

// MARK: - HubCache path helpers (MIRROR)
//
// MIRROR: hubDirNameHelper
//   Keep byte-identical with PopGuy/Modules/ProviderLayer/LocalEngine/MLXHelperManager.swift
//   hubDirName(for:) until the helper is refactored to share the function.
//   Same logic: "models--" + repoID with "/" replaced by "--".

/// Maps a HuggingFace repo id to its HubCache directory name.
/// Source of truth: swift-huggingface HubCache.repoDirectory — "models--{ns}--{name}".
private func hubDirNameHelper(for repoID: String) -> String {
    "models--" + repoID.replacingOccurrences(of: "/", with: "--")
}

/// Returns the total byte count of all regular files inside the model's `blobs/` directory.
/// Returns 0 if the directory does not exist or any enumeration error occurs — never throws.
private func blobsDirSize(cacheBase: URL, modelID: String) -> Int64 {
    let blobsDir = cacheBase
        .appendingPathComponent(hubDirNameHelper(for: modelID))
        .appendingPathComponent("blobs")
    guard let enumerator = FileManager.default.enumerator(
        at: blobsDir,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    ) else { return 0 }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            total += Int64(size)
        }
    }
    return total
}

// MARK: - Constants

/// Maximum line length in bytes before the line is rejected (OOM prevention).
/// The cap is enforced during accumulation — no oversize buffer is ever allocated.
private let kMaxLineLengthBytes = 8 * 1024 * 1024  // 8 MB
private let kWatchdogIntervalSeconds: TimeInterval = 30

/// Idle timeout in seconds, parsed from POPGUY_MLX_IDLE_SECONDS at startup.
/// 0 means "never unload" (watchdog disabled). Default: 300 (5 minutes).
private let kIdleTimeoutSeconds: TimeInterval = {
    if let raw = ProcessInfo.processInfo.environment["POPGUY_MLX_IDLE_SECONDS"],
       let parsed = Int(raw), parsed >= 0 {
        return TimeInterval(parsed)
    }
    return 300
}()

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

    // Watchdog: unload model (and exit) after sustained inactivity.
    // Disabled when kIdleTimeoutSeconds == 0 (never unload).
    let watchdog = Task.detached {
        guard kIdleTimeoutSeconds > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(kWatchdogIntervalSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let idle = await activity.idleSeconds()
            if idle >= kIdleTimeoutSeconds {
                await runner.unload()
                // Exit so the helper process RAM is also freed.
                // Re-launch happens automatically on next use.
                fflush(stdout)
                exit(0)
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

            case .status:
                writeResponse(.status(loadedModelID: await runner.loadedModelID()))

            case .unload:
                await runner.unload()
                writeResponse(.done)

            case .download(let modelID):
                let modelDownloader = ModelDownloader(hubClient: sharedHubClient)
                // Shared mutable state for the two progress paths.
                // Both paths run on @MainActor so access is serialized.
                let state = DownloadProgressState()

                // Disk-polling sampler: every ~1 s, sum blob sizes on disk and emit
                // a progress fraction derived from on-disk bytes vs. expectedTotal.
                // This unblocks the progress bar during large Xet downloads where
                // Foundation Progress stays near 0 until the blob finishes.
                // The task captures `state` (a let binding), which is @MainActor and
                // therefore implicitly Sendable — no @unchecked, no suppressions.
                let sampler = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 s
                        guard !Task.isCancelled else { break }
                        let expectedTotal = state.expectedTotal
                        guard expectedTotal > 0 else { continue }
                        let onDisk = blobsDirSize(cacheBase: sharedHubCacheDir, modelID: modelID)
                        let diskFraction = min(1.0, Double(onDisk) / Double(expectedTotal))
                        // Monotonic: never go backwards.
                        let fraction = max(diskFraction, state.highWater)
                        state.highWater = fraction
                        writeResponse(.progress(
                            modelID: modelID,
                            fraction: fraction,
                            downloadedBytes: onDisk,
                            totalBytes: expectedTotal
                        ))
                    }
                }
                defer { sampler.cancel() }

                do {
                    _ = try await modelDownloader.downloadSnapshot(
                        modelID: modelID,
                        progressHandler: { progress in
                            // Use fractionCompleted to aggregate child file progress.
                            // progress.completedUnitCount stays 0 on the parent; only
                            // fractionCompleted correctly reflects child progress.
                            //
                            // Capture expectedTotal from the first callback where
                            // totalUnitCount is positive (used by the disk sampler).
                            let total = progress.totalUnitCount
                            if state.expectedTotal == 0, total > 0 {
                                state.expectedTotal = total
                            }
                            let fraction = max(0.0, min(1.0, progress.fractionCompleted))
                            // Monotonic: take the best of Foundation progress and disk sampler.
                            let bestFraction = max(fraction, state.highWater)
                            state.highWater = bestFraction
                            let downloaded = Int64(Double(total) * bestFraction)
                            writeResponse(.progress(
                                modelID: modelID,
                                fraction: bestFraction,
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
