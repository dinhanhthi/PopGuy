// MLXHelperManagerTests.swift
// PopGuyTests
//
// Tests for MLXHelperManager using a stub shell script as the "helper" executable.
// The stub echoes protocol JSON lines (ready/token/done/progress/error/exit) to exercise
// the IPC plumbing without any MLX dependencies.
//
// Stub generate modes (selected by the `input` field value):
//   "echo"    → token:echo, done
//   "slow"    → sleep 0.2, token:slow-a, sleep 0.2, token:slow-b, sleep 0.2, token:slow-c, done
//               (used by cancel-leak test: read 1 token, cancel; slow-b/slow-c would leak)
//   "error"   → error response (no done)
//   "quit"    → exits immediately (no done)
//   any other → token:hello, token:" world", done
//
// Stub download modes (selected by the `modelID` field value, matched by substring):
//   contains "error" → error response (no done)
//   contains "quit"  → exits immediately (no done)
//   any other        → progress 0.5, progress 1.0, done
//
// `emitReady` param (default true): if false, the stub never emits ready — used for
// startup-timeout tests.

import Foundation
import Testing
@testable import PopGuy

// MARK: - Timeout helper

/// Runs `operation` and cancels it after `seconds` if it hasn't finished.
/// Throws `MLXHelperError.ipcError` on timeout so a hung test fails fast.
private func collectWithTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MLXHelperError.ipcError("Test timed out after \(seconds)s")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Stub helper script

/// Writes a temporary shell script that stands in for PopGuyMLXHelper.
/// - Parameter emitReady: If false, the stub never emits `{"type":"ready"}`.
///   Use this for startup-timeout tests.
@discardableResult
private func writeStubHelper(emitReady: Bool = true) throws -> URL {
    let tmpDir = FileManager.default.temporaryDirectory
    let stubURL = tmpDir.appendingPathComponent("StubPopGuyMLXHelper-\(UUID().uuidString)")

    let readyLine = emitReady ? #"printf '{"type":"ready"}\n'"# : "# no ready"

    let script = #"""
    #!/bin/sh
    # Stub PopGuyMLXHelper for unit testing.
    """# + "\n" + readyLine + #"""


    # Track loaded model id (stateful stub).
    loaded_model_id=""

    while IFS= read -r line; do
        case "$line" in
            *'"type":"generate"'*|*'"type": "generate"'*)
                mode=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('input',''))" 2>/dev/null || echo "")
                loaded_model_id=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('modelID',''))" 2>/dev/null || echo "")
                case "$mode" in
                    echo)
                        printf '{"type":"token","delta":"echo"}\n'
                        printf '{"type":"done"}\n'
                        ;;
                    slow)
                        sleep 0.2
                        printf '{"type":"token","delta":"slow-a"}\n'
                        sleep 0.2
                        printf '{"type":"token","delta":"slow-b"}\n'
                        sleep 0.2
                        printf '{"type":"token","delta":"slow-c"}\n'
                        printf '{"type":"done"}\n'
                        ;;
                    error)
                        printf '{"type":"error","message":"stub error"}\n'
                        ;;
                    quit)
                        exit 0
                        ;;
                    *)
                        printf '{"type":"token","delta":"hello"}\n'
                        printf '{"type":"token","delta":" world"}\n'
                        printf '{"type":"done"}\n'
                        ;;
                esac
                ;;
            *'"type":"download"'*|*'"type": "download"'*)
                modelID=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('modelID',''))" 2>/dev/null || echo "")
                case "$modelID" in
                    *error*)
                        printf '{"type":"error","message":"download stub error"}\n'
                        ;;
                    *quit*)
                        exit 0
                        ;;
                    *)
                        printf '{"type":"progress","modelID":"test","fraction":0.5,"downloadedBytes":512,"totalBytes":1024}\n'
                        printf '{"type":"progress","modelID":"test","fraction":1.0,"downloadedBytes":1024,"totalBytes":1024}\n'
                        printf '{"type":"done"}\n'
                        ;;
                esac
                ;;
            *'"type":"ping"'*|*'"type": "ping"'*)
                printf '{"type":"ready"}\n'
                ;;
            *'"type":"unload"'*|*'"type": "unload"'*)
                loaded_model_id=""
                printf '{"type":"done"}\n'
                ;;
            *'"type":"status"'*|*'"type": "status"'*)
                if [ -n "$loaded_model_id" ]; then
                    printf '{"type":"status","modelID":"%s"}\n' "$loaded_model_id"
                else
                    printf '{"type":"status"}\n'
                fi
                ;;
            *)
                ;;
        esac
    done
    """#

    try script.write(to: stubURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: stubURL.path
    )
    return stubURL
}

// MARK: - generate tests

@Suite("MLXHelperManager stub IPC", .serialized)
struct MLXHelperManagerTests {

    // MARK: - Happy path

    @Test("generate streams expected tokens and finishes cleanly")
    func generateStreamsTokens() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        let stream = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: "You are helpful.",
            input: "Say hello.",
            maxTokens: 64,
            temperature: 0.7
        )

        let tokens: [String] = try await collectWithTimeout(seconds: 10) {
            var collected: [String] = []
            for try await token in stream { collected.append(token) }
            return collected
        }

        await manager.shutdown()
        #expect(tokens == ["hello", " world"])
    }

    @Test("generate concatenates to expected full text")
    func generateConcatenatesTokens() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        let stream = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: nil,
            input: "Hello.",
            maxTokens: 128,
            temperature: 0.7
        )

        let result: String = try await collectWithTimeout(seconds: 10) {
            var text = ""
            for try await token in stream { text += token }
            return text
        }

        await manager.shutdown()
        #expect(result == "hello world")
    }

    // MARK: - 7a: helper error → stream throws

    @Test("7a: helper error response causes generate stream to throw")
    func generateThrowsOnHelperError() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        let stream = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: nil,
            input: "error",
            maxTokens: 10,
            temperature: 0.7
        )

        let didThrow: Bool = try await collectWithTimeout(seconds: 10) {
            do {
                for try await _ in stream { }
                return false
            } catch {
                return true
            }
        }

        await manager.shutdown()
        #expect(didThrow, "Expected generate stream to throw when helper sends error response")
    }

    // MARK: - 7b: process exits mid-stream without done → stream fails, not hangs

    @Test("7b: process exit mid-stream causes generate stream to fail, not hang")
    func generateFailsOnMidStreamExit() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        let stream = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: nil,
            input: "quit",
            maxTokens: 10,
            temperature: 0.7
        )

        let didThrow: Bool = try await collectWithTimeout(seconds: 10) {
            do {
                for try await _ in stream { }
                return false
            } catch {
                return true
            }
        }

        await manager.shutdown()
        #expect(didThrow, "Expected generate stream to throw when process exits without done")
    }

    // MARK: - 7c: real overlap — second request does not receive first's tokens

    @Test("7c: second generate does not receive tokens from first generate")
    func generateOverlapDoesNotLeakTokens() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)

        // Start A in "slow" mode (0.2 s between tokens). A is provably in-flight
        // (activeRequest is set) when B starts. We deliberately do NOT consume A.
        _ = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: nil,
            input: "slow",          // stub: slow-a, slow-b, slow-c
            maxTokens: 64,
            temperature: 0.7
        )

        // B starts while A's process is still running.
        // cancelAndRelaunch() sees activeRequest != .none → kills P1, launches P2.
        let streamB = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: nil,
            input: "echo",
            maxTokens: 64,
            temperature: 0.7
        )

        let tokensB: [String] = try await collectWithTimeout(seconds: 15) {
            var collected: [String] = []
            for try await token in streamB { collected.append(token) }
            return collected
        }

        await manager.shutdown()

        #expect(!tokensB.contains("slow-a"),
                "A's token 'slow-a' leaked into B's stream: \(tokensB)")
        #expect(!tokensB.contains("slow-b"),
                "A's token 'slow-b' leaked into B's stream: \(tokensB)")
        #expect(tokensB == ["echo"],
                "Expected B's stream to contain [\"echo\"], got: \(tokensB)")
    }

    // MARK: - (a) cancel-leak regression

    @Test("(a) cancel-leak: cancelled stream does not leak tokens into next request")
    func cancelledStreamDoesNotLeakTokens() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)

        // Partially consume stream A (read exactly 1 token from "slow" mode), then cancel.
        // slow-b and slow-c are still queued on the helper's stdout.
        // After cancel, the process must be torn down so its pending tokens cannot
        // appear in stream B.
        let streamA = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: nil,
            input: "slow",
            maxTokens: 64,
            temperature: 0.7
        )

        // Simulate toolbar cancel: cancel the Task while it is suspended on next().
        // In "slow" mode: slow-a arrives at ~0.2 s, then the iterator suspends on
        // next() for another 0.2 s waiting for slow-b.
        // Cancelling during that window triggers onTermination(.cancelled) on the
        // continuation → handleGenerateTermination → teardownProcess → epoch bump.
        //
        // IMPORTANT: the loop body must NOT sleep — a sleep inside the body causes
        // the CancellationError to be caught by the try-for-await and the iterator
        // exits via .finished(CancellationError), NOT .cancelled.
        let epochBeforeCancel = await manager.currentEpoch()
        let consumerTask = Task {
            for try await _ in streamA {
                // No sleep — loop immediately back to next() so the task is
                // suspended there when we cancel from outside.
            }
        }
        // Wait past slow-a (~0.2 s), then cancel while iterator awaits slow-b.
        try await Task.sleep(nanoseconds: 300_000_000)  // 300 ms: slow-a at ~0.2s, slow-b at ~0.4s
        consumerTask.cancel()
        _ = try? await consumerTask.value  // wait for task to finish

        // Poll until the epoch bumps (onTermination Task hops onto the actor).
        try await collectWithTimeout(seconds: 5) {
            while true {
                let epoch = await manager.currentEpoch()
                if epoch > epochBeforeCancel { return () }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        // Start B — must get a clean process, not the one that has slow-b/slow-c queued.
        let streamB = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: nil,
            input: "echo",
            maxTokens: 64,
            temperature: 0.7
        )

        let tokensB: [String] = try await collectWithTimeout(seconds: 10) {
            var collected: [String] = []
            for try await token in streamB { collected.append(token) }
            return collected
        }

        await manager.shutdown()

        #expect(!tokensB.contains("slow-b"),
                "Leaked 'slow-b' from cancelled stream into B: \(tokensB)")
        #expect(!tokensB.contains("slow-c"),
                "Leaked 'slow-c' from cancelled stream into B: \(tokensB)")
        #expect(tokensB == ["echo"],
                "Expected B's stream to contain [\"echo\"], got: \(tokensB)")
    }

    // MARK: - (b) startup timeout

    @Test("(b) startup timeout: generate throws startupTimeout when helper never emits ready")
    func generateThrowsOnStartupTimeout() async throws {
        // Stub that never emits ready — launchIfNeeded() will time out.
        let stubURL = try writeStubHelper(emitReady: false)
        defer { try? FileManager.default.removeItem(at: stubURL) }

        // 300 ms timeout — fast enough for CI, long enough to be reliable.
        let manager = MLXHelperManager(
            helperURL: stubURL,
            supported: true,
            readyTimeoutNanos: 300_000_000
        )

        var thrownError: Error?
        do {
            _ = try await manager.generate(
                modelID: "gemma-4-e2b",
                systemPrompt: nil,
                input: "hello",
                maxTokens: 10,
                temperature: 0.7
            )
        } catch {
            thrownError = error
        }

        await manager.shutdown()
        #expect(thrownError != nil, "Expected generate to throw on startup timeout")
        if let err = thrownError as? MLXHelperError, case .startupTimeout = err {
            // Correct — got the expected error type.
        } else {
            #expect(Bool(false),
                    "Expected MLXHelperError.startupTimeout, got: \(String(describing: thrownError))")
        }
    }

    // MARK: - (c) cancel → epoch bump (teardown-on-cancel regression)

    @Test("(c) cancel causes teardown: epoch bumps after consumer cancels an in-flight request")
    func cancelBumpsEpoch() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)

        // Launch the helper and record the epoch after the first generate is ready.
        let streamA = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: nil,
            input: "slow",
            maxTokens: 64,
            temperature: 0.7
        )
        let epochAfterLaunch = await manager.currentEpoch()

        // Simulate consumer cancel: cancel the Task while it is suspended on next().
        // No sleep inside loop body — that would cause CancellationError to propagate
        // via the error path (.finished) rather than the cancellation path (.cancelled).
        let consumerTask = Task {
            for try await _ in streamA {
                // No sleep — loop back to next() immediately.
            }
        }
        // Wait past slow-a (~0.2 s), then cancel while iterator awaits slow-b.
        try await Task.sleep(nanoseconds: 300_000_000)
        consumerTask.cancel()
        _ = try? await consumerTask.value

        // Poll until the epoch bumps (the onTermination Task hops onto the actor
        // asynchronously; give it up to 5 s to complete).
        let epochAfterCancel: Int = try await collectWithTimeout(seconds: 5) {
            while true {
                let epoch = await manager.currentEpoch()
                if epoch > epochAfterLaunch { return epoch }
                try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms poll
            }
        }

        #expect(epochAfterCancel > epochAfterLaunch,
                "Expected epoch to increase after cancel (teardown), got \(epochAfterLaunch) → \(epochAfterCancel)")

        await manager.shutdown()
    }

    // MARK: - download

    @Test("download yields progress events and finishes cleanly")
    func downloadYieldsProgress() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        let stream = try await manager.download(modelID: "gemma-4-e2b")

        let progressEvents: [DownloadProgress] = try await collectWithTimeout(seconds: 10) {
            var collected: [DownloadProgress] = []
            for try await event in stream { collected.append(event) }
            return collected
        }

        await manager.shutdown()
        #expect(progressEvents.count == 2, "Expected 2 progress events, got \(progressEvents.count)")
        #expect(progressEvents.last?.fraction == 1.0)
        #expect(progressEvents.last?.downloadedBytes == 1024)
        #expect(progressEvents.last?.totalBytes == 1024)
    }

    @Test("download first progress event has fraction 0.5")
    func downloadFirstProgressFraction() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        let stream = try await manager.download(modelID: "gemma-4-e2b")

        let events: [DownloadProgress] = try await collectWithTimeout(seconds: 10) {
            var collected: [DownloadProgress] = []
            for try await event in stream { collected.append(event) }
            return collected
        }

        await manager.shutdown()
        #expect(events.first?.fraction == 0.5)
        #expect(events.first?.downloadedBytes == 512)
    }

    // MARK: - (d) download error + exit paths

    @Test("(d) download: helper error response causes download stream to throw")
    func downloadThrowsOnHelperError() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        // modelID containing "error" triggers the stub's error branch.
        let stream = try await manager.download(modelID: "gemma-4-e2b-error")

        let didThrow: Bool = try await collectWithTimeout(seconds: 10) {
            do {
                for try await _ in stream { }
                return false
            } catch {
                return true
            }
        }

        await manager.shutdown()
        #expect(didThrow, "Expected download stream to throw when helper sends error response")
    }

    @Test("(d) download: process exit mid-stream causes download stream to fail, not hang")
    func downloadFailsOnMidStreamExit() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        // modelID containing "quit" triggers the stub's exit branch.
        let stream = try await manager.download(modelID: "gemma-4-e2b-quit")

        let didThrow: Bool = try await collectWithTimeout(seconds: 10) {
            do {
                for try await _ in stream { }
                return false
            } catch {
                return true
            }
        }

        await manager.shutdown()
        #expect(didThrow, "Expected download stream to throw when process exits without done")
    }

    // MARK: - Capability guard

    @Test("generate throws when supported = false")
    func generateThrowsWhenNotSupported() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: false)
        var didThrow = false
        do {
            _ = try await manager.generate(
                modelID: "gemma-4-e2b",
                systemPrompt: nil,
                input: "test",
                maxTokens: 10,
                temperature: 0.7
            )
        } catch {
            didThrow = true
        }
        #expect(didThrow, "Expected generate to throw when supported = false")
    }

    @Test("download throws when supported = false")
    func downloadThrowsWhenNotSupported() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: false)
        var didThrow = false
        do {
            _ = try await manager.download(modelID: "gemma-4-e2b")
        } catch {
            didThrow = true
        }
        #expect(didThrow, "Expected download to throw when supported = false")
    }

    // MARK: - Missing helper

    @Test("generate throws when helper binary is missing")
    func generateThrowsWhenHelperMissing() async throws {
        let missingURL = URL(fileURLWithPath: "/nonexistent/PopGuyMLXHelper")
        let manager = MLXHelperManager(helperURL: missingURL, supported: true)
        var didThrow = false
        do {
            _ = try await manager.generate(
                modelID: "gemma-4-e2b",
                systemPrompt: nil,
                input: "test",
                maxTokens: 10,
                temperature: 0.7
            )
        } catch {
            didThrow = true
        }
        #expect(didThrow, "Expected generate to throw when helper binary is missing")
    }
}

// MARK: - hubDirName tests (Item 8)

@Suite("hubDirName")
struct HubDirNameTests {

    @Test("slash in repo id becomes double-dash")
    func slashBecomesDoubleDash() {
        #expect(hubDirName(for: "mlx-community/gemma-4-e2b-it-4bit")
                == "models--mlx-community--gemma-4-e2b-it-4bit")
    }

    @Test("no slash gives single models-- prefix")
    func noSlash() {
        #expect(hubDirName(for: "localmodel") == "models--localmodel")
    }

    @Test("multiple slashes all become double-dash")
    func multipleSlashes() {
        #expect(hubDirName(for: "a/b/c") == "models--a--b--c")
    }

    @Test("all catalog repo ids produce models-- prefix with no slashes")
    func catalogRepoIDsHavePrefix() {
        for model in LocalModelCatalog.all {
            let dir = hubDirName(for: model.repoID)
            #expect(dir.hasPrefix("models--"),
                    "Expected 'models--' prefix for \(model.repoID), got: \(dir)")
            #expect(!dir.contains("/"),
                    "Expected no '/' in dir name for \(model.repoID), got: \(dir)")
        }
    }
}

// MARK: - installedModels / delete tests (Item 8)

@Suite("installedModels and delete", .serialized)
struct InstalledModelsTests {

    @Test("installedModels returns empty when cache dir is empty")
    func emptyWhenNothingInstalled() async {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hub-test-empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = MLXHelperManager(
            helperURL: URL(fileURLWithPath: "/stub"),
            supported: false,
            hubCacheBaseURL: tmpDir
        )
        let installed = await manager.installedModels()
        #expect(installed.isEmpty, "Expected no installed models; got: \(installed)")
    }

    @Test("installedModels detects a model whose refs/main exists")
    func detectsInstalledModel() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hub-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dirName = hubDirName(for: "mlx-community/gemma-4-e2b-it-4bit")
        let refsDir = tmpDir.appendingPathComponent(dirName).appendingPathComponent("refs")
        try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
        try "snapshot-hash".write(
            to: refsDir.appendingPathComponent("main"),
            atomically: true,
            encoding: .utf8
        )

        let manager = MLXHelperManager(
            helperURL: URL(fileURLWithPath: "/stub"),
            supported: false,
            hubCacheBaseURL: tmpDir
        )
        let installed = await manager.installedModels()
        #expect(installed == ["gemma-4-e2b"], "Expected [\"gemma-4-e2b\"]; got: \(installed)")
    }

    @Test("delete removes the model directory")
    func deleteRemovesDirectory() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hub-test-del-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dirName = hubDirName(for: "mlx-community/gemma-4-e2b-it-4bit")
        let modelDir = tmpDir.appendingPathComponent(dirName)
        let refsDir = modelDir.appendingPathComponent("refs")
        try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
        try "hash".write(
            to: refsDir.appendingPathComponent("main"),
            atomically: true,
            encoding: .utf8
        )

        let manager = MLXHelperManager(
            helperURL: URL(fileURLWithPath: "/stub"),
            supported: false,
            hubCacheBaseURL: tmpDir
        )

        let before = await manager.installedModels()
        #expect(before == ["gemma-4-e2b"])

        await manager.delete(modelID: "gemma-4-e2b")

        let modelDirExists = FileManager.default.fileExists(atPath: modelDir.path)
        #expect(!modelDirExists, "Expected model directory to be removed after delete()")

        let after = await manager.installedModels()
        #expect(after.isEmpty, "Expected no installed models after delete; got: \(after)")
    }
}

// MARK: - Memory lifecycle tests (loadedModelID / unloadModel / applyIdleTimeoutChange)

@Suite("MLXHelperManager memory lifecycle", .serialized)
struct MLXHelperManagerMemoryTests {

    // MARK: - loadedModelID

    @Test("loadedModelID returns nil when process is not running")
    func loadedModelIDNilWhenNotRunning() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        // Never launch the helper — process is nil.
        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        let id = await manager.loadedModelID()
        #expect(id == nil, "Expected nil when no process has been launched")
    }

    @Test("loadedModelID returns nil when no model is loaded in the running helper")
    func loadedModelIDNilWhenNoModelLoaded() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        // Launch the helper via generate (so it's running), then query status immediately.
        // The stub tracks loaded_model_id; after a fresh launch with no generate, it is "".
        // Actually: we need to ensure the helper is running without a generate call.
        // The easiest way: generate first (to start the helper), then query.
        // After generate finishes, the stub has set loaded_model_id to the modelID.
        // Instead, use a manager with a 5 s timeout, and use ping (which the helper handles
        // as a side-effect of launching). But launchIfNeeded is private.
        // Approach: generate with "echo" mode (finishes quickly), then unload via unloadModel,
        // then query status — loaded_model_id should be "".
        let manager = MLXHelperManager(helperURL: stubURL, supported: true, readyTimeoutNanos: 5_000_000_000)

        // Start a generate and wait for it to complete (process stays running after).
        let stream = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: nil,
            input: "echo",
            maxTokens: 10,
            temperature: 0.7
        )
        try await collectWithTimeout(seconds: 10) {
            for try await _ in stream { }
        }

        // Unload model so the stub clears loaded_model_id.
        await manager.unloadModel()
        // Give the unload response (done) time to arrive.
        try await Task.sleep(nanoseconds: 200_000_000)

        let id = await manager.loadedModelID()
        #expect(id == nil, "Expected nil after unload, got: \(String(describing: id))")

        await manager.shutdown()
    }

    @Test("loadedModelID returns the model id the stub reports after generate")
    func loadedModelIDReturnsLoadedID() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true, readyTimeoutNanos: 5_000_000_000)

        // Run a generate so the stub sets loaded_model_id.
        let stream = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: nil,
            input: "echo",
            maxTokens: 10,
            temperature: 0.7
        )
        try await collectWithTimeout(seconds: 10) {
            for try await _ in stream { }
        }

        let id = await manager.loadedModelID()
        #expect(id == "gemma-4-e2b", "Expected gemma-4-e2b, got: \(String(describing: id))")

        await manager.shutdown()
    }

    // MARK: - unloadModel

    @Test("unloadModel sends unload request and stub clears loaded_model_id")
    func unloadModelClearsID() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true, readyTimeoutNanos: 5_000_000_000)

        // Launch helper via generate.
        let stream = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: nil,
            input: "echo",
            maxTokens: 10,
            temperature: 0.7
        )
        try await collectWithTimeout(seconds: 10) {
            for try await _ in stream { }
        }

        // Confirm model is loaded.
        let beforeID = await manager.loadedModelID()
        #expect(beforeID == "gemma-4-e2b", "Pre-condition: expected gemma-4-e2b loaded")

        // Unload and allow the done response to arrive.
        await manager.unloadModel()
        try await Task.sleep(nanoseconds: 300_000_000)

        let afterID = await manager.loadedModelID()
        #expect(afterID == nil, "Expected nil after unloadModel(), got: \(String(describing: afterID))")

        await manager.shutdown()
    }

    @Test("unloadModel is a no-op when process is not running")
    func unloadModelNoOpWhenNotRunning() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        // Should not throw or hang — just a no-op.
        await manager.unloadModel()
        // Success: reaching here without error.
    }

    // MARK: - applyIdleTimeoutChange

    @Test("applyIdleTimeoutChange tears down idle process so next launch gets new env")
    func applyIdleTimeoutChangeTeardownAndRelaunch() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true, readyTimeoutNanos: 5_000_000_000)

        // Launch helper via generate.
        let stream = try await manager.generate(
            modelID: "gemma-4-e2b",
            systemPrompt: nil,
            input: "echo",
            maxTokens: 10,
            temperature: 0.7
        )
        try await collectWithTimeout(seconds: 10) {
            for try await _ in stream { }
        }

        let epochBeforeChange = await manager.currentEpoch()

        // Apply idle change while process is idle — should tear it down.
        await manager.applyIdleTimeoutChange(60)

        // Poll for epoch bump (teardown is synchronous on actor).
        let epochAfterChange: Int = try await collectWithTimeout(seconds: 5) {
            while true {
                let e = await manager.currentEpoch()
                if e > epochBeforeChange { return e }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        #expect(epochAfterChange > epochBeforeChange,
                "Expected epoch to increase after applyIdleTimeoutChange on idle process")

        // loadedModelID should now return nil since the process was torn down.
        let id = await manager.loadedModelID()
        #expect(id == nil, "Expected nil after teardown, got: \(String(describing: id))")

        await manager.shutdown()
    }
}
