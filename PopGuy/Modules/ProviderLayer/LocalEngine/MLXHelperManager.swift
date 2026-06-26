// MLXHelperManager.swift
// PopGuy — ProviderLayer/LocalEngine
//
// Long-lived helper process manager for PopGuyMLXHelper.
//
// Architecture:
//   - One Process is kept alive across multiple requests (lazy, restarted on demand).
//   - ALL public API is actor-isolated; only one call executes at a time.
//   - A background Task reads stdout lines via FileHandle.bytes.lines and delivers
//     each decoded HelperResponse back to the actor via deliver(_:epoch:).
//   - On startup the helper emits {"type":"ready"}. launchIfNeeded() uses a stored
//     CheckedContinuation<Void, Error> to await that first ready line.
//   - A startup timeout (default 15 s, injectable for tests) resumes the ready
//     waiter with startupTimeout if the helper hangs before printing "ready".
//   - stderr is drained continuously to prevent the >64 KB pipe-buffer deadlock.
//
// Single-flight invariant:
//   The wire protocol carries no request IDs, so concurrent requests MUST NOT
//   share the same running process. When generate/download is called while another
//   request is in flight, the current process is torn down and relaunched before
//   the new request starts. Combined with the epoch guard (below), this guarantees
//   A's tokens can never reach B's continuation.
//
// Epoch guard:
//   `processEpoch` increments every time a new process is launched (and whenever
//   teardownProcess() runs). The reader task captures its epoch at launch time and
//   passes it to deliver(_:epoch:) and handleProcessExit(epoch:). Calls from a
//   stale reader (old epoch) are silently ignored — they cannot null out the fresh
//   process or fail the new readyWaiter.
//
// onTermination (cancel-leak prevention):
//   Both stream continuations capture their requestID and reason.
//   - .cancelled  → teardownProcess() + clear activeRequest (bumps epoch; stale reader
//                   is ignored; next request relaunches a clean helper).
//   - .finished   → just clear activeRequest (normal or errored completion; process
//                   stays alive for reuse on the next request).
//   The requestID guard ensures A's late termination cannot act on B's request.
//
// Wire protocol codec:
//   HelperRequest and HelperResponse are `public nonisolated enum` in
//   LocalHelperProtocol.swift, so their Codable conformances are accessible from
//   any context. JSONEncoder/JSONDecoder are used directly.
//
// Swift 6 strict concurrency: all shared state is actor-isolated. No @unchecked.

import Foundation

// MARK: - DownloadProgress

/// Progress update from the helper during a model download.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor so all
// properties can be read from any concurrency context.
public nonisolated struct DownloadProgress: Sendable {
    public nonisolated let fraction: Double
    public nonisolated let downloadedBytes: Int64?
    public nonisolated let totalBytes: Int64?
}

// MARK: - MLXHelperError

enum MLXHelperError: Error, LocalizedError {
    case unsupported(String)
    case helperNotFound(String)
    case launchFailed(String)
    case ipcError(String)
    case processExited
    case startupTimeout

    var errorDescription: String? {
        switch self {
        case .unsupported(let reason):   return "Local MLX not supported: \(reason)"
        case .helperNotFound:            return "MLX helper binary not found."
        case .launchFailed(let reason):  return "Failed to launch MLX helper: \(reason)"
        case .ipcError(let detail):      return "MLX helper IPC error: \(detail)"
        case .processExited:             return "MLX helper exited unexpectedly."
        case .startupTimeout:            return "MLX helper did not become ready within the timeout."
        }
    }
}

// MARK: - Nonisolated JSON helpers

/// Decode a stdout line from the helper.
/// HelperResponse is `public nonisolated enum` so its Codable conformance is callable here.
private nonisolated func decodeLine(_ line: String) -> HelperResponse? {
    guard let data = line.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(HelperResponse.self, from: data)
}

/// Encode a HelperRequest to a JSON line.
/// HelperRequest is `public nonisolated enum` so its Codable conformance is callable here.
private nonisolated func encodeLine(_ request: HelperRequest) throws -> Data {
    try JSONEncoder().encode(request)
}

// MARK: - HubCache path helper

/// Maps a HuggingFace repo id to its HubCache directory name.
/// Source of truth: swift-huggingface HubCache.repoDirectory — "models--{ns}--{name}".
/// All calls in installedModels() and delete() go through this function.
nonisolated func hubDirName(for repoID: String) -> String {
    "models--" + repoID.replacingOccurrences(of: "/", with: "--")
}

// MARK: - ActiveRequest

/// Which kind of stream continuation is currently waiting for helper output.
private enum ActiveRequest {
    case generate(AsyncThrowingStream<String, Error>.Continuation)
    case download(AsyncThrowingStream<DownloadProgress, Error>.Continuation)
    case none
}

// MARK: - StatusWaiter result

/// Internal result type for the status request continuation.
private enum StatusResult: Sendable {
    case loaded(String?)
    case failed(Error)
}

// MARK: - MLXHelperManager

/// Actor that owns and communicates with the long-lived PopGuyMLXHelper subprocess.
///
/// Use `MLXHelperManager.shared` in production.
/// Inject a stub URL and `supported: true` in tests.
actor MLXHelperManager {

    // MARK: - Shared singleton

    static let shared = MLXHelperManager()

    // MARK: - Configuration

    private let helperURL: URL
    private let isSupported: Bool
    private let hubCacheBaseURL: URL?    // nil → use default app-support path
    private let readyTimeoutNanos: UInt64

    // MARK: - Process state

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readerTask: Task<Void, Never>?

    /// Incremented every time a new process is launched.
    /// Reader tasks capture their epoch; stale readers are ignored.
    private var processEpoch: Int = 0

    // MARK: - Request state

    /// The currently active stream continuation, set synchronously before the
    /// request is sent to the helper so no response can arrive before the slot is set.
    private var activeRequest: ActiveRequest = .none

    /// Monotonically increasing counter: bumped each time a new activeRequest is set.
    /// Captured by `onTermination` closures so they can only clear the request they belong to.
    private var requestID: Int = 0

    /// One-shot continuation waiting for the helper's startup `ready` line.
    private var readyWaiter: CheckedContinuation<Void, Error>?

    /// Task running the 15-second startup timeout.
    private var readyTimeoutTask: Task<Void, Never>?

    /// One-shot continuation waiting for a `status` response.
    /// Resumes with the loaded model id (nil = nothing loaded).
    private var statusWaiter: CheckedContinuation<String?, Error>?

    /// Task running the status request timeout (reuses readyTimeoutNanos).
    private var statusTimeoutTask: Task<Void, Never>?

    /// Configured idle timeout in seconds passed to the helper via env. 0 = never unload.
    private var idleSeconds: Int = 300

    // MARK: - Init

    /// Production init: bundled helper path + real MLXCapability check.
    init() {
        let bundledURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/PopGuyMLXHelper")
        self.helperURL = bundledURL
        self.isSupported = MLXCapability.isSupported
        self.hubCacheBaseURL = nil
        self.readyTimeoutNanos = 15_000_000_000
    }

    /// Injectable init for tests: supply a stub executable, override capability,
    /// an optional temp directory for the hub cache, and an optional ready timeout.
    init(
        helperURL: URL,
        supported: Bool = true,
        hubCacheBaseURL: URL? = nil,
        readyTimeoutNanos: UInt64 = 15_000_000_000
    ) {
        self.helperURL = helperURL
        self.isSupported = supported
        self.hubCacheBaseURL = hubCacheBaseURL
        self.readyTimeoutNanos = readyTimeoutNanos
    }

    // MARK: - Capability guard

    private func checkSupported() throws {
        guard isSupported else {
            throw MLXHelperError.unsupported(MLXCapability.unsupportedReason)
        }
    }

    // MARK: - Launch

    /// Ensure the helper process is running and the startup `ready` has been received.
    ///
    /// IMPORTANT: This always cancels any in-flight request before relaunching
    /// to satisfy the single-flight invariant. Callers are responsible for
    /// finishing the previous stream before calling this if they don't want
    /// interruption (generate/download already handle this).
    private func launchIfNeeded() async throws {
        if let existing = process, existing.isRunning { return }

        // Tear down any dead state (increments epoch).
        teardownProcess()

        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw MLXHelperError.helperNotFound(helperURL.path)
        }

        let proc = Process()
        proc.executableURL = helperURL
        proc.arguments = []
        proc.environment = [
            "HOME":                      NSHomeDirectory(),
            "USER":                      NSUserName(),
            "LOGNAME":                   NSUserName(),
            "PATH":                      "/usr/bin:/bin",
            "LANG":                      "en_US.UTF-8",
            "LC_ALL":                    "en_US.UTF-8",
            "POPGUY_MLX_IDLE_SECONDS":   "\(idleSeconds)",
        ]

        let stdoutPipe = Pipe()
        let stdinPipe  = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardInput  = stdinPipe
        proc.standardError  = stderrPipe

        do {
            try proc.run()
        } catch {
            throw MLXHelperError.launchFailed(error.localizedDescription)
        }

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        processEpoch += 1
        let myEpoch = processEpoch

        // Drain stderr continuously to prevent the >64 KB pipe-buffer deadlock.
        let stderrHandle = stderrPipe.fileHandleForReading
        Task.detached {
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }
            }
        }

        // Start line-reader. Captures epoch at launch; stale calls are ignored.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        readerTask = Task { [weak self] in
            do {
                for try await line in stdoutHandle.bytes.lines {
                    guard let self else { return }
                    if let response = decodeLine(line) {
                        await self.deliver(response, epoch: myEpoch)
                    }
                    // Unrecognized lines (debug output from helper) are silently dropped.
                }
            } catch {
                // I/O error on stdout — treat as process exit.
            }
            guard let self else { return }
            await self.handleProcessExit(epoch: myEpoch)
        }

        // Arm the startup timeout (injectable for tests). Cancelled when ready arrives.
        let timeoutNanos = readyTimeoutNanos
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanos)
            } catch {
                return  // Cancelled by ready signal — normal path.
            }
            guard let self else { return }
            await self.handleReadyTimeout(epoch: myEpoch)
        }
        readyTimeoutTask = timeoutTask

        // Wait for the startup `ready` line (or timeout / exit error).
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.readyWaiter = cont
        }
    }

    // MARK: - Process teardown

    /// Tear down process, cancel reader, and fail any waiting continuations.
    /// Increments `processEpoch` so stale reader tasks are ignored after return.
    private func teardownProcess() {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        statusTimeoutTask?.cancel()
        statusTimeoutTask = nil

        process?.terminate()
        process = nil
        stdinHandle = nil
        readerTask?.cancel()
        readerTask = nil
        processEpoch += 1  // Invalidate the old epoch.

        if let waiter = readyWaiter {
            readyWaiter = nil
            waiter.resume(throwing: MLXHelperError.processExited)
        }

        if let waiter = statusWaiter {
            statusWaiter = nil
            waiter.resume(throwing: MLXHelperError.processExited)
        }
    }

    // MARK: - Response delivery (called by readerTask, epoch-guarded)

    /// Deliver a decoded response.
    /// Guards against stale reader tasks: if `epoch` != `processEpoch`, the
    /// reader belongs to a previous process launch and is silently ignored.
    private func deliver(_ response: HelperResponse, epoch: Int) {
        guard epoch == processEpoch else { return }

        switch response {
        case .ready:
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            if let waiter = readyWaiter {
                readyWaiter = nil
                waiter.resume()
            }

        case .token(let delta):
            if case .generate(let cont) = activeRequest {
                cont.yield(delta)
            }

        case .progress(let modelID, let fraction, let downloadedBytes, let totalBytes):
            if case .download(let cont) = activeRequest {
                cont.yield(DownloadProgress(
                    fraction: fraction,
                    downloadedBytes: downloadedBytes,
                    totalBytes: totalBytes
                ))
            }
            _ = modelID  // The model id is in the progress line but not surfaced here.

        case .done:
            finishActiveRequest()

        case .error(let message):
            failActiveRequest(MLXHelperError.ipcError(message))

        case .status(let loadedModelID):
            statusTimeoutTask?.cancel()
            statusTimeoutTask = nil
            if let waiter = statusWaiter {
                statusWaiter = nil
                waiter.resume(returning: loadedModelID)
            }
        }
    }

    private func handleProcessExit(epoch: Int) {
        guard epoch == processEpoch else { return }

        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        statusTimeoutTask?.cancel()
        statusTimeoutTask = nil

        if let waiter = readyWaiter {
            readyWaiter = nil
            waiter.resume(throwing: MLXHelperError.processExited)
        }

        if let waiter = statusWaiter {
            statusWaiter = nil
            waiter.resume(throwing: MLXHelperError.processExited)
        }

        // Only fail the active request when one is in-flight.
        // When activeRequest == .none, the process exited idle (e.g. watchdog triggered
        // exit-on-idle) — this is normal and must not surface as an error.
        if case .none = activeRequest {
            process = nil
            stdinHandle = nil
        } else {
            failActiveRequest(MLXHelperError.processExited)
            process = nil
            stdinHandle = nil
        }
    }

    private func handleReadyTimeout(epoch: Int) {
        guard epoch == processEpoch else { return }

        // Only act if WE still own the waiter — if deliver(.ready) already resumed
        // it, the process is healthy and must NOT be torn down.
        guard let waiter = readyWaiter else { return }
        readyWaiter = nil

        // Resume the waiter first (correct error), then full teardown
        // (bumps epoch, cancels readerTask, nils process/stdin).
        // teardownProcess() sees readyWaiter == nil and skips its own resume.
        waiter.resume(throwing: MLXHelperError.startupTimeout)
        teardownProcess()
    }

    // MARK: - Request lifecycle

    private func finishActiveRequest() {
        switch activeRequest {
        case .generate(let cont): cont.finish()
        case .download(let cont): cont.finish()
        case .none: break
        }
        activeRequest = .none
    }

    private func failActiveRequest(_ error: Error) {
        switch activeRequest {
        case .generate(let cont): cont.finish(throwing: error)
        case .download(let cont): cont.finish(throwing: error)
        case .none: break
        }
        activeRequest = .none
    }

    // MARK: - Send request

    private func sendRequest(_ request: HelperRequest) throws {
        guard let handle = stdinHandle else {
            throw MLXHelperError.ipcError("Helper stdin not available.")
        }
        let data = try encodeLine(request)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MLXHelperError.ipcError("Failed to encode request as UTF-8.")
        }
        handle.write(Data((json + "\n").utf8))
    }

    // MARK: - Cancel prior request (single-flight enforcement)

    /// Ensure the helper is ready for a new request.
    ///
    /// When a request is idle (activeRequest == .none), the existing process is
    /// reused — no restart penalty. When a request is in-flight, the process is
    /// torn down first (enforcing the single-flight invariant: the wire protocol
    /// carries no request IDs, so concurrent requests cannot share a process).
    ///
    /// launchIfNeeded() increments the epoch so any stale reader is ignored.
    private func cancelAndRelaunch() async throws {
        if case .none = activeRequest {
            // Idle: reuse the existing process if it is still running.
            try await launchIfNeeded()
        } else {
            // In-flight: fail the active stream immediately so its consumer
            // sees an error, then tear down (increments epoch) and relaunch.
            failActiveRequest(MLXHelperError.processExited)
            teardownProcess()
            try await launchIfNeeded()
        }
    }

    // MARK: - Public API

    /// Stream token deltas from the helper for a generate request.
    ///
    /// Single-flight: if a prior request is in flight, the process is restarted
    /// before the new request starts, ensuring no cross-request token leakage.
    ///
    /// onTermination: if the consumer cancels before `done`, `activeRequest` is
    /// cleared on the actor so no stale tokens reach the next request.
    func generate(
        modelID: String,
        systemPrompt: String?,
        input: String,
        maxTokens: Int,
        temperature: Double
    ) async throws -> AsyncThrowingStream<String, Error> {
        try checkSupported()

        // Bump requestID FIRST, before the cancelAndRelaunch() suspension.
        // This ensures that any prior request's onTermination handler (which
        // captures the old requestID) is already blocked by the guard
        // `requestID == id` during the launchIfNeeded() await, even if the
        // prior stream is dropped and triggers .cancelled mid-suspension.
        requestID &+= 1
        let myRequestID = requestID

        // Cancel any in-flight request and ensure a fresh process epoch.
        try await cancelAndRelaunch()

        // Build the stream and capture its continuation BEFORE sending the request.
        // This is synchronous, so no deliver() call can race between here and
        // setting activeRequest.
        var captured: AsyncThrowingStream<String, Error>.Continuation?
        let stream = AsyncThrowingStream<String, Error> { cont in
            captured = cont
        }
        guard let continuation = captured else {
            throw MLXHelperError.ipcError("Failed to create generate stream.")
        }

        // Set onTermination so consumer cancellation tears down the process (preventing
        // leftover tokens from leaking into the next request) while normal completion
        // just clears activeRequest (allowing process reuse).
        continuation.onTermination = { [weak self] reason in
            guard let self else { return }
            Task { await self.handleGenerateTermination(reason, requestID: myRequestID) }
        }

        activeRequest = .generate(continuation)

        do {
            try sendRequest(HelperRequest.generate(
                modelID: modelID,
                systemPrompt: systemPrompt,
                input: input,
                maxTokens: maxTokens,
                temperature: temperature
            ))
        } catch {
            failActiveRequest(error)
            throw error
        }

        return stream
    }

    /// Stream download progress for a model.
    ///
    /// Same single-flight and onTermination guarantees as generate.
    func download(modelID: String) async throws -> AsyncThrowingStream<DownloadProgress, Error> {
        try checkSupported()

        // Bump requestID FIRST (same reason as in generate — see comment there).
        requestID &+= 1
        let myRequestID = requestID

        try await cancelAndRelaunch()

        var captured: AsyncThrowingStream<DownloadProgress, Error>.Continuation?
        let stream = AsyncThrowingStream<DownloadProgress, Error> { cont in
            captured = cont
        }
        guard let continuation = captured else {
            throw MLXHelperError.ipcError("Failed to create download stream.")
        }

        continuation.onTermination = { [weak self] reason in
            guard let self else { return }
            Task { await self.handleDownloadTermination(reason, requestID: myRequestID) }
        }

        activeRequest = .download(continuation)

        do {
            try sendRequest(HelperRequest.download(modelID: modelID))
        } catch {
            failActiveRequest(error)
            throw error
        }

        return stream
    }

    // MARK: - onTermination dispatch (called off-actor, hops back via Task)

    /// Dispatched from generate's onTermination handler.
    ///
    /// - The `requestID == id` guard MUST run first: a late `.cancelled` from
    ///   request A must NOT act on request B's healthy process.
    /// - `.cancelled`: consumer abandoned the stream mid-flight. Tear down the
    ///   process so its queued tokens cannot leak into the next request. The
    ///   next generate/download will relaunch a clean helper.
    /// - `.finished`: normal completion or helper-sent error. The process already
    ///   sent `done`/`error` and activeRequest was cleared by finishActiveRequest /
    ///   failActiveRequest; this is a no-op for those paths.
    private func handleGenerateTermination(
        _ reason: AsyncThrowingStream<String, Error>.Continuation.Termination,
        requestID id: Int
    ) {
        guard requestID == id else { return }
        switch reason {
        case .cancelled:
            activeRequest = .none   // clear before teardown (teardown doesn't clear it)
            teardownProcess()       // bumps processEpoch; stale reader is ignored
        default:
            activeRequest = .none
        }
    }

    /// Dispatched from download's onTermination handler. Same semantics as generate.
    private func handleDownloadTermination(
        _ reason: AsyncThrowingStream<DownloadProgress, Error>.Continuation.Termination,
        requestID id: Int
    ) {
        guard requestID == id else { return }
        switch reason {
        case .cancelled:
            activeRequest = .none
            teardownProcess()
        default:
            activeRequest = .none
        }
    }

    // MARK: - New public API (memory lifecycle controls)

    /// Returns the id of the model currently loaded in the helper, or nil if no process
    /// is running or no model is loaded.
    ///
    /// Never launches the helper — returns nil immediately when the process is not running
    /// so the idle-exit state is not accidentally revived by a status poll.
    func loadedModelID() async -> String? {
        guard let proc = process, proc.isRunning else { return nil }

        // Guard: only one status waiter at a time.
        guard statusWaiter == nil else { return nil }

        let myEpoch = processEpoch
        let timeoutNanos = readyTimeoutNanos

        do {
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
                self.statusWaiter = cont

                // Arm timeout.
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanos)
                    } catch {
                        return  // Cancelled by status reply — normal path.
                    }
                    guard let self else { return }
                    await self.handleStatusTimeout(epoch: myEpoch)
                }
                self.statusTimeoutTask = timeoutTask

                // Send the status request. If send fails, resolve the continuation immediately.
                do {
                    try self.sendRequest(.status)
                } catch {
                    self.statusTimeoutTask?.cancel()
                    self.statusTimeoutTask = nil
                    self.statusWaiter = nil
                    cont.resume(throwing: error)
                }
            }
        } catch {
            return nil
        }
    }

    private func handleStatusTimeout(epoch: Int) {
        guard epoch == processEpoch else { return }
        guard let waiter = statusWaiter else { return }
        statusWaiter = nil
        statusTimeoutTask?.cancel()
        statusTimeoutTask = nil
        waiter.resume(throwing: MLXHelperError.startupTimeout)
    }

    /// Send an `.unload` request to the helper if it is currently running.
    ///
    /// Does not wait for a response (the helper emits `.done`, which the reader task
    /// handles via `finishActiveRequest` — a no-op when `activeRequest == .none`).
    /// No-op when the process is not running.
    func unloadModel() async {
        guard let proc = process, proc.isRunning else { return }
        // Only send when idle to stay race-free with the single-flight machinery.
        guard case .none = activeRequest else { return }
        try? sendRequest(.unload)
    }

    /// Apply a new idle timeout value.
    ///
    /// Updates the stored value. When the helper is running and idle (no active
    /// request, no pending ready handshake), tears it down immediately so the
    /// next launch picks up the new env value. When a request is active, the new
    /// value is stored and will be used on the next relaunch.
    func applyIdleTimeoutChange(_ seconds: Int) {
        idleSeconds = seconds
        // Only tear down when idle: no active request, no in-progress launch (readyWaiter == nil).
        guard let proc = process, proc.isRunning else { return }
        guard case .none = activeRequest else { return }
        guard readyWaiter == nil else { return }
        teardownProcess()
    }

    // MARK: - Installed model detection

    /// Returns catalog model ids whose files are present in the on-disk HubCache.
    ///
    /// Presence is indicated by `refs/main` existing inside the model's HubCache folder.
    ///
    /// HubCache folder layout (matches swift-huggingface HubCache.repoDirectory):
    ///   `<hubCacheBaseURL>/models--{ns}--{name}/refs/main`
    /// where `/` in the repo id is replaced with `--`.
    ///
    /// NOTE: The store no longer uses `installedModels()` as the authority for which
    /// models are installed — it uses its own persisted completed set. This method is
    /// kept for legacy test coverage (MLXHelperManagerTests) and must not be removed.
    func installedModels() -> [String] {
        let hubDir = resolvedHubDir()

        return LocalModelCatalog.all.compactMap { model in
            let refsMain = hubDir
                .appendingPathComponent(hubDirName(for: model.repoID))
                .appendingPathComponent("refs")
                .appendingPathComponent("main")
            return FileManager.default.fileExists(atPath: refsMain.path) ? model.id : nil
        }
    }

    /// Returns true if the HubCache model directory exists on disk for the given catalog model id.
    ///
    /// Used by `SettingsStore.refreshInstalledLocalModels()` as a reconciliation check:
    /// a model id in the persisted completed set is dropped when its directory is absent
    /// (external deletion). This is NOT used to infer installation from disk alone.
    func modelDirExists(modelID: String) -> Bool {
        guard let model = LocalModelCatalog.model(for: modelID) else { return false }
        let hubDir = resolvedHubDir()
        let modelDir = hubDir.appendingPathComponent(hubDirName(for: model.repoID))
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    /// Remove all cached files for a catalog model.
    func delete(modelID: String) {
        guard let model = LocalModelCatalog.model(for: modelID) else { return }
        let hubDir = resolvedHubDir()
        try? FileManager.default.removeItem(
            at: hubDir.appendingPathComponent(hubDirName(for: model.repoID))
        )
    }

    /// Resolves the HubCache directory: injected (tests) or default app-support path.
    private func resolvedHubDir() -> URL {
        if let injected = hubCacheBaseURL {
            return injected
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return appSupport
            .appendingPathComponent("PopGuy")
            .appendingPathComponent("models")
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
    }

    // MARK: - Test accessors

    /// Current process epoch. Increments on every launch and every teardown.
    /// Exposed for tests that assert teardown-on-cancel via epoch bump.
    func currentEpoch() -> Int { processEpoch }

    // MARK: - Lifecycle

    /// Terminate the helper if running and idle (no active request).
    func terminateIfIdle() {
        guard let proc = process, proc.isRunning else { return }
        guard case .none = activeRequest else { return }
        teardownProcess()
    }

    /// Unconditionally terminate the helper.
    func shutdown() {
        finishActiveRequest()
        teardownProcess()
    }
}
