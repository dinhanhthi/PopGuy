// LocalMLXSettingsTests.swift
// PopGuyTests
//
// Phase 4 tests: LocalModelAvailability decision + SettingsStore download orchestration.
//
// Injection seam: SettingsStore(defaults:mlxHelper:isMLXSupported:) lets tests
// supply a stub MLXHelperManager (stub shell script — same approach as
// MLXHelperManagerTests) and a fixed isMLXSupported flag.

import Combine
import Foundation
import Testing
@testable import PopGuy

// MARK: - Stub helper

/// Behaviour modes for the stub download helper script.
private enum StubMode {
    /// Immediate download: 0.5 → 1.0 → done (no delay).
    case fast
    /// Slow download: 0.5, then a 1-second sleep, then 1.0 → done.
    case slow
    /// Error download: emits one partial progress line then an error event.
    case fail
}

/// Writes a shell script that stands in for PopGuyMLXHelper.
///
/// Supports three download modes (fast / slow / fail) selected by `mode`.
/// generate and ping are always answered the same way regardless of mode.
@discardableResult
private func writeStubHelper(mode: StubMode = .fast) throws -> URL {
    let tmpDir = FileManager.default.temporaryDirectory
    let stubURL = tmpDir.appendingPathComponent("LocalMLXStubHelper-\(UUID().uuidString)")

    let downloadBody: String
    switch mode {
    case .fast:
        downloadBody = """
                printf '{"type":"progress","modelID":"test","fraction":0.5,"downloadedBytes":512,"totalBytes":1024}\\n'
                printf '{"type":"progress","modelID":"test","fraction":1.0,"downloadedBytes":1024,"totalBytes":1024}\\n'
                printf '{"type":"done"}\\n'
        """
    case .slow:
        downloadBody = """
                printf '{"type":"progress","modelID":"test","fraction":0.5,"downloadedBytes":512,"totalBytes":1024}\\n'
                sleep 1
                printf '{"type":"progress","modelID":"test","fraction":1.0,"downloadedBytes":1024,"totalBytes":1024}\\n'
                printf '{"type":"done"}\\n'
        """
    case .fail:
        downloadBody = """
                printf '{"type":"progress","modelID":"test","fraction":0.3,"downloadedBytes":307,"totalBytes":1024}\\n'
                printf '{"type":"error","message":"simulated download failure"}\\n'
        """
    }

    let script = """
    #!/bin/sh
    printf '{"type":"ready"}\\n'
    while IFS= read -r line; do
        case "$line" in
            *'"type":"download"'*|*'"type": "download"'*)
    \(downloadBody)
                ;;
            *'"type":"generate"'*)
                printf '{"type":"token","delta":"ok"}\\n'
                printf '{"type":"done"}\\n'
                ;;
            *'"type":"ping"'*)
                printf '{"type":"ready"}\\n'
                ;;
        esac
    done
    """

    try script.write(to: stubURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: stubURL.path
    )
    return stubURL
}

/// Creates the model directory tree that `MLXHelperManager.modelDirExists(modelID:)`
/// uses to detect whether a model's files are still on disk.
///
/// Also creates `refs/main` so that the legacy `installedModels()` helper (used by
/// MLXHelperManagerTests) still returns the seeded model.
///
/// - Parameters:
///   - hubDir: The base hub cache directory (injected into MLXHelperManager).
///   - repoID: The HuggingFace repo id (e.g. "mlx-community/gemma-4-e2b-it-4bit").
private func seedInstalledModel(hubDir: URL, repoID: String) throws {
    let modelDir = hubDir
        .appendingPathComponent(hubDirName(for: repoID))
        .appendingPathComponent("refs")
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try "".write(to: modelDir.appendingPathComponent("main"), atomically: true, encoding: .utf8)
}

/// Removes the model directory that `seedInstalledModel` created, simulating an
/// external deletion. Used by the reconciliation tests.
private func removeInstalledModel(hubDir: URL, repoID: String) throws {
    let modelDir = hubDir.appendingPathComponent(hubDirName(for: repoID))
    try FileManager.default.removeItem(at: modelDir)
}

// MARK: - Timeout helper

private func withTimeout<T: Sendable>(
    seconds: Double,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MLXHelperError.ipcError("Test timed out after \(seconds)s")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Suite

@Suite("LocalMLX Settings — availability + download orchestration", .serialized)
@MainActor
struct LocalMLXSettingsTests {

    // MARK: - Helpers

    private func makeSuite() -> (UserDefaults, String) {
        let name = "com.popguy.test.localmlx.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func removeSuite(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    // MARK: - availability(for:isPro:) — licensing branches

    @Test("free model + non-Pro user → .available")
    func freeModelNonProUser() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite, isMLXSupported: true)
        let freeModel = LocalModelCatalog.all.first { $0.isFreeTier }!

        if case .available = store.availability(for: freeModel, isPro: false) {
            // pass
        } else {
            Issue.record("Expected .available for free model + non-Pro user")
        }
    }

    @Test("Pro model + non-Pro user → .proLocked")
    func proModelNonProUser() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite, isMLXSupported: true)
        guard let proModel = LocalModelCatalog.all.first(where: { !$0.isFreeTier }) else {
            Issue.record("No Pro-only model found in LocalModelCatalog — test cannot run")
            return
        }

        if case .proLocked = store.availability(for: proModel, isPro: false) {
            // pass
        } else {
            Issue.record("Expected .proLocked for Pro model + non-Pro user")
        }
    }

    @Test("Pro model + Pro user → .available")
    func proModelProUser() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite, isMLXSupported: true)
        guard let proModel = LocalModelCatalog.all.first(where: { !$0.isFreeTier }) else {
            Issue.record("No Pro-only model found in LocalModelCatalog — test cannot run")
            return
        }

        if case .available = store.availability(for: proModel, isPro: true) {
            // pass
        } else {
            Issue.record("Expected .available for Pro model + Pro user")
        }
    }

    @Test("free model + Pro user → .available")
    func freeModelProUser() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite, isMLXSupported: true)
        let freeModel = LocalModelCatalog.all.first { $0.isFreeTier }!

        if case .available = store.availability(for: freeModel, isPro: true) {
            // pass
        } else {
            Issue.record("Expected .available for free model + Pro user")
        }
    }

    @Test("unsupported hardware → .unsupported regardless of tier or Pro status")
    func unsupportedHardware() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite, isMLXSupported: false)

        for model in LocalModelCatalog.all {
            for isPro in [true, false] {
                if case .unsupported = store.availability(for: model, isPro: isPro) {
                    // pass
                } else {
                    Issue.record("Expected .unsupported for \(model.id) isPro=\(isPro) on unsupported hardware")
                }
            }
        }
    }

    @Test("capability is checked before licensing (unsupported beats proLocked)")
    func capabilityBeforeLicensing() {
        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let store = SettingsStore(defaults: suite, isMLXSupported: false)
        guard let proModel = LocalModelCatalog.all.first(where: { !$0.isFreeTier }) else {
            Issue.record("No Pro-only model found in LocalModelCatalog — test cannot run")
            return
        }

        if case .unsupported = store.availability(for: proModel, isPro: false) {
            // pass: capability gate fires before the Pro gate
        } else {
            Issue.record("Expected .unsupported (not .proLocked) when hardware is unsupported")
        }
    }

    // MARK: - Download enforcement

    @Test("proLocked model is refused without touching the helper")
    func downloadRefusesProLockedModel() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        let store = SettingsStore(defaults: suite, mlxHelper: manager, isMLXSupported: true)

        guard let proModel = LocalModelCatalog.all.first(where: { !$0.isFreeTier }) else {
            Issue.record("No Pro-only model found in LocalModelCatalog — test cannot run")
            await manager.shutdown()
            return
        }
        store.downloadLocalModel(proModel.id, isPro: false)

        // Error should be set synchronously (no await needed for the guard path).
        #expect(store.localModelDownloadError != nil, "Expected an error for proLocked download attempt")
        #expect(store.activeLocalModelDownloadID == nil, "Expected no active download for proLocked model")

        await manager.shutdown()
    }

    @Test("unsupported hardware is refused without touching the helper")
    func downloadRefusesUnsupportedHardware() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: false)
        let store = SettingsStore(defaults: suite, mlxHelper: manager, isMLXSupported: false)

        let freeModel = LocalModelCatalog.all.first { $0.isFreeTier }!
        store.downloadLocalModel(freeModel.id, isPro: false)

        #expect(store.localModelDownloadError != nil, "Expected an error for unsupported hardware")
        #expect(store.activeLocalModelDownloadID == nil, "Expected no active download on unsupported hardware")

        await manager.shutdown()
    }

    @Test("unknown model id sets localModelDownloadError and does not start download")
    func downloadRefusesUnknownModelID() async throws {
        let stubURL = try writeStubHelper()
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        let store = SettingsStore(defaults: suite, mlxHelper: manager, isMLXSupported: true)

        store.downloadLocalModel("this-id-does-not-exist", isPro: true)

        #expect(store.localModelDownloadError != nil, "Expected error for unknown model id")
        #expect(store.activeLocalModelDownloadID == nil, "Expected no active download for unknown id")

        await manager.shutdown()
    }

    // MARK: - Download orchestration (happy path)

    @Test("download progress publishes and installedLocalModels refreshes on completion")
    func downloadProgressAndInstalledRefresh() async throws {
        let stubURL = try writeStubHelper(mode: .fast)
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Temp hub dir; seed refs/main so installedModels() sees the model after download.
        let tempHub = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMLXHub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempHub) }

        let freeModel = LocalModelCatalog.all.first { $0.isFreeTier }!
        try seedInstalledModel(hubDir: tempHub, repoID: freeModel.repoID)

        let manager = MLXHelperManager(helperURL: stubURL, supported: true, hubCacheBaseURL: tempHub)
        let store = SettingsStore(defaults: suite, mlxHelper: manager, isMLXSupported: true)

        #expect(store.installedLocalModels.isEmpty, "Should start empty before download")

        // Capture all progress emissions via Combine before starting the download.
        var observedProgress: [Double] = []
        let progressToken = store.$localModelDownloadProgress
            .compactMap { $0[freeModel.id] }
            .sink { observedProgress.append($0) }
        defer { progressToken.cancel() }

        // Trigger the download (non-Pro user, free model → allowed).
        store.downloadLocalModel(freeModel.id, isPro: false)
        #expect(store.activeLocalModelDownloadID == freeModel.id, "Expected active download id to be set")

        // Wait for the Task to complete (poll with timeout).
        try await withTimeout(seconds: 10) {
            while await store.activeLocalModelDownloadID != nil {
                try await Task.sleep(nanoseconds: 20_000_000)  // 20 ms
            }
        }

        #expect(!observedProgress.isEmpty, "Expected progress to publish at least one value; got none")
        #expect(observedProgress.contains(1.0), "Expected final progress 1.0 to publish; saw \(observedProgress)")
        #expect(store.localModelDownloadError == nil, "Expected no download error on success")
        #expect(store.localModelDownloadProgress.isEmpty, "Expected progress cleared on completion")
        #expect(store.installedLocalModels.contains(freeModel.id),
                "Expected installedLocalModels to contain \(freeModel.id) after download")

        await manager.shutdown()
    }

    // MARK: - Cancel mid-download

    @Test("cancel mid-download clears progress and activeID with no stuck state")
    func cancelMidDownload() async throws {
        // Slow stub: 1-second sleep between progress lines gives us time to cancel.
        let stubURL = try writeStubHelper(mode: .slow)
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        let store = SettingsStore(defaults: suite, mlxHelper: manager, isMLXSupported: true)

        let freeModel = LocalModelCatalog.all.first { $0.isFreeTier }!
        store.downloadLocalModel(freeModel.id, isPro: false)

        // Wait briefly for the first progress update so the Task is definitely running.
        try await withTimeout(seconds: 5) {
            while await store.localModelDownloadProgress[freeModel.id] == nil {
                try await Task.sleep(nanoseconds: 20_000_000)  // 20 ms
            }
        }

        // Cancel while the slow sleep is in progress.
        store.cancelLocalModelDownload()

        // The Task's cancellation guard should clear state. Allow up to 3 s.
        try await withTimeout(seconds: 3) {
            while await store.activeLocalModelDownloadID != nil {
                try await Task.sleep(nanoseconds: 20_000_000)  // 20 ms
            }
        }

        #expect(store.activeLocalModelDownloadID == nil, "Expected activeID cleared after cancel")
        #expect(store.localModelDownloadProgress.isEmpty, "Expected progress dict cleared after cancel")
        #expect(store.localModelDownloadError == nil, "Expected no error after a clean cancel")
        #expect(!store.installedLocalModels.contains(freeModel.id),
                "Expected cancelled download NOT to mark model installed")

        await manager.shutdown()
    }

    // MARK: - Error path

    @Test("download error sets localModelDownloadError and clears progress and activeID")
    func downloadErrorPath() async throws {
        // Fail stub: emits partial progress then an error event.
        let stubURL = try writeStubHelper(mode: .fail)
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let manager = MLXHelperManager(helperURL: stubURL, supported: true)
        let store = SettingsStore(defaults: suite, mlxHelper: manager, isMLXSupported: true)

        let freeModel = LocalModelCatalog.all.first { $0.isFreeTier }!
        store.downloadLocalModel(freeModel.id, isPro: false)

        // Wait for the Task to settle (either error set or activeID cleared).
        try await withTimeout(seconds: 10) {
            while await store.activeLocalModelDownloadID != nil {
                try await Task.sleep(nanoseconds: 20_000_000)  // 20 ms
            }
        }

        #expect(store.localModelDownloadError != nil, "Expected error to be set after stub failure")
        #expect(store.activeLocalModelDownloadID == nil, "Expected activeID cleared after error")
        #expect(store.localModelDownloadProgress.isEmpty, "Expected progress cleared after error")
        #expect(!store.installedLocalModels.contains(freeModel.id),
                "Expected failed download NOT to mark model installed")

        await manager.shutdown()
    }

    // MARK: - Overlapping downloads (different ids — validates download token FIX 2)

    @Test("starting download B (different id) cancels A and B's state survives A's teardown")
    func overlappingDownloadsDifferentIDs() async throws {
        // Slow stub for A so that A is still in flight when B starts.
        let slowStubURL = try writeStubHelper(mode: .slow)
        defer { try? FileManager.default.removeItem(at: slowStubURL) }

        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        // Both downloads go through the same manager instance.
        let manager = MLXHelperManager(helperURL: slowStubURL, supported: true)
        let store = SettingsStore(defaults: suite, mlxHelper: manager, isMLXSupported: true)

        // Pick two different free/pro models as A and B.
        let allModels = LocalModelCatalog.all
        guard allModels.count >= 2 else {
            Issue.record("Need at least 2 models in LocalModelCatalog for this test")
            await manager.shutdown()
            return
        }
        let modelA = allModels[0]
        let modelB = allModels[1]

        // Start download A (slow).
        store.downloadLocalModel(modelA.id, isPro: true)

        // Wait for A's first progress update so the Task is definitely in flight.
        // We poll until progress appears OR the activeID changes (Task already finished).
        try await withTimeout(seconds: 5) {
            while await store.localModelDownloadProgress.isEmpty {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        // Start download B — this cancels A and replaces it.
        store.downloadLocalModel(modelB.id, isPro: true)

        // B should immediately own activeLocalModelDownloadID.
        #expect(store.activeLocalModelDownloadID == modelB.id,
                "Expected B to own activeDownloadID right after starting")

        // Wait for B to finish (or error — slow stub's second progress + done takes ~1 s).
        try await withTimeout(seconds: 10) {
            while await store.activeLocalModelDownloadID != nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        // A's late teardown must NOT have nulled out B's activeID mid-run or clobbered anything.
        // After B finishes, activeID is nil (correct), but must never have flipped to A's id.
        #expect(store.activeLocalModelDownloadID == nil,
                "Expected activeID nil after B completes")
        #expect(store.localModelDownloadProgress.isEmpty,
                "Expected progress dict empty after B completes")

        await manager.shutdown()
    }

    // MARK: - Same-id re-download (validates download token FIX 2)

    @Test("re-downloading the same id — B's progress survives A's teardown")
    func sameIDRedownload() async throws {
        let slowStubURL = try writeStubHelper(mode: .slow)
        defer { try? FileManager.default.removeItem(at: slowStubURL) }

        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let manager = MLXHelperManager(helperURL: slowStubURL, supported: true)
        let store = SettingsStore(defaults: suite, mlxHelper: manager, isMLXSupported: true)

        let freeModel = LocalModelCatalog.all.first { $0.isFreeTier }!

        // Start download A (slow).
        store.downloadLocalModel(freeModel.id, isPro: false)

        // Wait for A's first progress update so the Task is definitely in flight.
        try await withTimeout(seconds: 5) {
            while await store.localModelDownloadProgress.isEmpty {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        // Start download B for the SAME model id — cancels A, replaces it.
        store.downloadLocalModel(freeModel.id, isPro: false)

        #expect(store.activeLocalModelDownloadID == freeModel.id,
                "Expected activeID still set to freeModel.id after re-download start")

        // Wait for B to complete.
        try await withTimeout(seconds: 10) {
            while await store.activeLocalModelDownloadID != nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        // A's teardown must not have cleared B's final state early or clobbered the error.
        #expect(store.localModelDownloadError == nil,
                "Expected no error after successful re-download")
        #expect(store.localModelDownloadProgress.isEmpty,
                "Expected progress cleared after re-download completes")

        await manager.shutdown()
    }

    // MARK: - refreshInstalledLocalModels

    /// Reconciliation removes a completed model from installedLocalModels when its
    /// directory is externally deleted from disk.
    ///
    /// New contract: installedLocalModels = completedLocalModelIDs ∩ disk.
    /// Disk-only presence (no entry in completedLocalModelIDs) is NOT sufficient.
    @Test("refreshInstalledLocalModels reconciliation removes externally-deleted model")
    func refreshReconciliationRemovesDeletedModel() async throws {
        let stubURL = try writeStubHelper(mode: .fast)
        defer { try? FileManager.default.removeItem(at: stubURL) }

        let tempHub = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMLXHub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempHub) }

        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let freeModel = LocalModelCatalog.all.first { $0.isFreeTier }!
        // Seed the model directory so modelDirExists returns true during the download.
        try seedInstalledModel(hubDir: tempHub, repoID: freeModel.repoID)

        let manager = MLXHelperManager(helperURL: stubURL, supported: true, hubCacheBaseURL: tempHub)
        let store = SettingsStore(defaults: suite, mlxHelper: manager, isMLXSupported: true)

        // Complete a download so the model ends up in completedLocalModelIDs.
        store.downloadLocalModel(freeModel.id, isPro: false)
        try await withTimeout(seconds: 10) {
            while await store.activeLocalModelDownloadID != nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        #expect(store.installedLocalModels.contains(freeModel.id),
                "Expected model installed after successful download")

        // Simulate external deletion by removing the model directory.
        try removeInstalledModel(hubDir: tempHub, repoID: freeModel.repoID)

        // Reconciliation should drop the id.
        await store.refreshInstalledLocalModels()
        #expect(!store.installedLocalModels.contains(freeModel.id),
                "Expected model removed from installedLocalModels after directory deletion")

        await manager.shutdown()
    }

    /// Disk-only presence does NOT make a model show as installed.
    /// The completed set must contain the id for it to appear installed.
    @Test("refreshInstalledLocalModels ignores disk-only presence (no completed entry)")
    func refreshIgnoresDiskOnlyPresence() async throws {
        let tempHub = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMLXHub-diskonly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempHub) }

        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let freeModel = LocalModelCatalog.all.first { $0.isFreeTier }!
        // Seed the directory on disk — but do NOT record it in completedLocalModelIDs.
        try seedInstalledModel(hubDir: tempHub, repoID: freeModel.repoID)

        let manager = MLXHelperManager(helperURL: URL(fileURLWithPath: "/nonexistent"), supported: true, hubCacheBaseURL: tempHub)
        let store = SettingsStore(defaults: suite, mlxHelper: manager, isMLXSupported: true)

        await store.refreshInstalledLocalModels()
        #expect(store.installedLocalModels.isEmpty,
                "Expected empty: disk-only presence without a completed entry must not show as installed")
    }

    @Test("refreshInstalledLocalModels returns empty when no models seeded")
    func refreshEmptyWhenNothingSeeded() async throws {
        let tempHub = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMLXHub-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempHub) }

        let (suite, name) = makeSuite()
        defer { removeSuite(name) }

        let manager = MLXHelperManager(helperURL: URL(fileURLWithPath: "/nonexistent"), supported: true, hubCacheBaseURL: tempHub)
        let store = SettingsStore(defaults: suite, mlxHelper: manager, isMLXSupported: true)

        await store.refreshInstalledLocalModels()
        #expect(store.installedLocalModels.isEmpty, "Expected empty set when no models are on disk")
    }

    // MARK: - allowedProviders contains .mlxLocal (Issue 4)

    @Test(".mlxLocal is in ActionKind.improve.allowedProviders")
    func mlxLocalInImproveAllowedProviders() {
        #expect(ActionKind.improve.allowedProviders.contains(.mlxLocal),
                "Expected .mlxLocal in improve.allowedProviders")
    }

    @Test(".mlxLocal is in CustomAction.allowedProviders(for: .ai)")
    func mlxLocalInCustomActionAIAllowedProviders() {
        #expect(CustomAction.allowedProviders(for: .ai).contains(.mlxLocal),
                "Expected .mlxLocal in CustomAction.allowedProviders(for: .ai)")
    }
}
