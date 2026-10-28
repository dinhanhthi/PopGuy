// CLIProcessRunner.swift
// PopGuy — ProviderLayer
//
// Shared subprocess streamer used by CLI-based provider adapters (Claude CLI,
// Codex CLI, Gemini CLI). Spawns a child process, streams its stdout lines as
// an AsyncThrowingStream, and terminates the process on cancellation.
//
// Security: the child environment is built from scratch (no inherited env) and
// ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY are deliberately absent
// so the CLI uses subscription / OAuth authentication rather than an API key.
//
// Swift 6 concurrency: all shared mutable state is guarded by NSLock inside
// the @unchecked Sendable State box. The Process and Pipe are created and
// owned entirely within the stream closure; only Sendable values are captured
// across concurrency domains.

import Foundation

// MARK: - CLIProcessRunner

/// Shared helper for running a local CLI binary and streaming its stdout lines.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum CLIProcessRunner {

    /// Spawn `executablePath` with `arguments` and stream stdout lines.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the CLI binary.
    ///   - arguments:      Command-line arguments passed to the binary.
    ///   - extraEnv:       Additional environment variables merged on top of the
    ///                     minimal base env (HOME / USER / LOGNAME / PATH).
    ///   - stdin:          Optional text written to the process's stdin pipe after
    ///                     the process starts. Pass `nil` for processes that read no stdin.
    /// - Returns: An `AsyncThrowingStream` that yields one `String` per stdout line.
    ///            On cancellation the child process is terminated. On non-zero exit
    ///            the stream finishes throwing `ProviderError.httpError`.
    static func run(
        executablePath: String,
        arguments: [String],
        extraEnv: [String: String] = [:],
        stdin: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // Validate the binary exists before spawning.
            guard FileManager.default.fileExists(atPath: executablePath) else {
                continuation.finish(
                    throwing: ProviderError.transport(
                        "CLI not found at \(executablePath). Set the path in Settings."
                    )
                )
                return
            }

            let state = RunState()

            continuation.onTermination = { _ in
                state.terminate()
            }

            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.currentDirectoryURL = FileManager.default.temporaryDirectory

                // Build environment from scratch — do NOT inherit the parent process env.
                // USER and LOGNAME are required for the claude CLI's Keychain lookup.
                // PATH = dir(executable) + standard system paths; node lives alongside
                // the codex / gemini binaries so the runtime is available without inheriting.
                // LANG / LC_ALL / LC_CTYPE ensure UTF-8 text encoding under Node CLIs
                // so multibyte characters are not mangled.
                let binDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
                var env: [String: String] = [
                    "HOME":     NSHomeDirectory(),
                    "USER":     NSUserName(),
                    "LOGNAME":  NSUserName(),
                    "PATH":     "\(binDir):/usr/bin:/bin",
                    "LANG":     "en_US.UTF-8",
                    "LC_ALL":   "en_US.UTF-8",
                    "LC_CTYPE": "en_US.UTF-8",
                ]
                // Never set ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY — their
                // absence forces CLI tools to use subscription / OAuth authentication.
                for (key, value) in extraEnv {
                    env[key] = value
                }
                process.environment = env

                // Stdout pipe — lines yielded to the stream consumer.
                let stdoutPipe = Pipe()
                process.standardOutput = stdoutPipe

                // Stderr pipe — drained concurrently to prevent the >64KB deadlock:
                // if the child fills the pipe buffer before exiting, write blocks,
                // the process never terminates, and terminationHandler never fires.
                let stderrPipe = Pipe()
                process.standardError = stderrPipe

                // Stdin pipe — written after the process starts.
                if stdin != nil {
                    process.standardInput = Pipe()
                }

                state.setProcess(process)

                // stdout readabilityHandler runs on a private GCD queue — must only
                // capture Sendable values (state box and continuation).
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    state.appendStdout(chunk) { line in
                        continuation.yield(line)
                    }
                }

                // stderr readabilityHandler — accumulates stderr raw (no line-splitting)
                // so the pipe buffer never fills even for verbose CLIs (codex/gemini).
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    state.appendStderr(chunk)
                }

                // terminationHandler also runs on a private queue.
                process.terminationHandler = { proc in
                    // Nil both handlers before draining tails. Note: setting
                    // readabilityHandler=nil does not cancel an already-dispatched
                    // handler invocation — there is a residual low-impact race where
                    // a queued handler fires after the tail drain. This is benign
                    // because appendStdout/appendStderr are lock-serialised: the tail
                    // drain always sees a consistent buffer state.
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    // Drain any remaining stdout tail through the same lock-serialised
                    // appendStdout path (finding 9: tail uses appendStdout, consistent).
                    let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if !stdoutTail.isEmpty {
                        state.appendStdout(stdoutTail) { line in
                            continuation.yield(line)
                        }
                    }
                    // Flush any final incomplete stdout line (no trailing newline).
                    state.flushStdoutRemainder { line in
                        continuation.yield(line)
                    }

                    // Drain any remaining stderr tail into the accumulated buffer.
                    let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !stderrTail.isEmpty {
                        state.appendStderr(stderrTail)
                    }

                    let exitCode = Int(proc.terminationStatus)
                    if exitCode != 0 {
                        let stderrSnippet = state.consumeStderr().map { String($0.prefix(500)) }
                        state.finish {
                            continuation.finish(
                                throwing: ProviderError.httpError(
                                    statusCode: exitCode,
                                    body: stderrSnippet
                                )
                            )
                        }
                    } else {
                        state.finish {
                            continuation.finish()
                        }
                    }
                }

                try process.run()

                // Write stdin after the process has started.
                if let stdinText = stdin,
                   let stdinPipe = process.standardInput as? Pipe {
                    if let data = stdinText.data(using: .utf8) {
                        stdinPipe.fileHandleForWriting.write(data)
                    }
                    try? stdinPipe.fileHandleForWriting.close()
                }

            } catch {
                continuation.finish(throwing: ProviderError.transport(error.localizedDescription))
            }
        }
    }
}

// MARK: - RunState

/// @unchecked Sendable container for mutable process state shared between
/// the readabilityHandler, terminationHandler, and onTermination closures.
/// All mutations are serialised through `lock`.
private final class RunState: @unchecked Sendable {

    // nonisolated(unsafe): SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor would otherwise
    // infer MainActor isolation on these stored properties. The @unchecked Sendable
    // conformance and NSLock serialisation provide the actual thread-safety guarantee.
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var stdoutBuffer = Data()
    nonisolated(unsafe) private var stderrBuffer = Data()
    nonisolated(unsafe) private var finished = false

    nonisolated func setProcess(_ p: Process) {
        lock.lock()
        defer { lock.unlock() }
        process = p
    }

    /// Terminate the child process (called on stream cancellation).
    nonisolated func terminate() {
        lock.lock()
        let p = process
        lock.unlock()
        p?.terminate()
    }

    /// Append `data` to the stdout line buffer and flush complete lines by calling
    /// `onLine` for each. May be called from any queue; serialised by `lock`.
    ///
    /// The lock is released before each `onLine` call to avoid reentrancy deadlock
    /// (continuation.yield re-enters arbitrary user code). It is re-acquired after
    /// the call before the next buffer scan.
    nonisolated func appendStdout(_ data: Data, onLine: (String) -> Void) {
        lock.lock()
        stdoutBuffer.append(data)
        while let newlineRange = stdoutBuffer.range(of: Data([0x0A])) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex ..< newlineRange.lowerBound]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex ... newlineRange.lowerBound)
            // Unlock before calling onLine to avoid reentrancy deadlock; re-lock after.
            lock.unlock()
            if let line = String(data: lineData, encoding: .utf8) {
                onLine(line)
            }
            lock.lock()
        }
        lock.unlock()
    }

    /// Flush any remaining bytes in stdoutBuffer as a final line (handles the case
    /// where the process output does not end with a newline). Lock-guarded.
    nonisolated func flushStdoutRemainder(onLine: (String) -> Void) {
        lock.lock()
        guard !stdoutBuffer.isEmpty else {
            lock.unlock()
            return
        }
        let remaining = stdoutBuffer
        stdoutBuffer = Data()
        // Unlock before calling onLine to avoid reentrancy deadlock; re-lock after.
        lock.unlock()
        if let line = String(data: remaining, encoding: .utf8) {
            onLine(line)
        }
    }

    /// Append `data` to the raw stderr accumulation buffer. Lock-guarded.
    nonisolated func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stderrBuffer.append(data)
    }

    /// Return the accumulated stderr as a UTF-8 string and clear the buffer.
    /// Returns `nil` if the buffer is empty or not valid UTF-8.
    nonisolated func consumeStderr() -> String? {
        lock.lock()
        let data = stderrBuffer
        stderrBuffer = Data()
        lock.unlock()
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Call `action` exactly once; subsequent calls are no-ops (guards double-finish).
    nonisolated func finish(_ action: () -> Void) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        action()
    }
}
