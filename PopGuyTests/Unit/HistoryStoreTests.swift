// HistoryStoreTests.swift
// PopGuyTests
//
// TDD: HistoryStore — record/persist/trim/preview/delete/clear round-trips
// against a temp file URL so tests never touch the real Application Support
// location. Each test uses a unique temp file and removes it via `defer`.

import Foundation
import Testing
@testable import PopGuy

// MARK: - HistoryStoreTests

@Suite("HistoryStore")
@MainActor
struct HistoryStoreTests {

    // MARK: - Helpers

    /// A unique temp file URL for one test run; caller removes it via `defer`.
    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
    }

    private func removeFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Record a run with sensible defaults; only override what a test cares about.
    @discardableResult
    private func record(
        _ store: HistoryStore,
        actionName: String = "Improve",
        input: String = "hello",
        output: String = "world",
        success: Bool = true,
        errorMessage: String? = nil,
        storeFullText: Bool = true
    ) -> HistoryStore {
        store.record(
            actionName: actionName,
            providerKind: .anthropic,
            model: "claude-sonnet-4-6",
            sourceBundleID: "com.example.app",
            sourceAppName: "Example",
            durationMs: 123,
            success: success,
            errorMessage: errorMessage,
            input: input,
            output: output,
            storeFullText: storeFullText
        )
        return store
    }

    // MARK: - Persistence round-trip

    @Test("record persists and re-loads newest-first")
    func recordRoundTrips() {
        let url = makeTempURL()
        defer { removeFile(url) }

        let store = HistoryStore(fileURL: url)
        record(store, actionName: "First", input: "a", output: "1")
        record(store, actionName: "Second", input: "b", output: "2")

        // Newest first in memory.
        #expect(store.records.count == 2)
        #expect(store.records[0].actionName == "Second")
        #expect(store.records[1].actionName == "First")

        // Re-load a fresh store from the same file — order and content survive.
        let reloaded = HistoryStore(fileURL: url)
        #expect(reloaded.records.count == 2)
        #expect(reloaded.records[0].actionName == "Second")
        #expect(reloaded.records[0].input == "b")
        #expect(reloaded.records[0].output == "2")
        #expect(reloaded.records[1].actionName == "First")
    }

    // MARK: - Cap

    @Test("recording past 500 trims to 500, dropping the oldest")
    func capTrimsOldest() {
        let url = makeTempURL()
        defer { removeFile(url) }

        let store = HistoryStore(fileURL: url)
        for i in 0..<(HistoryStore.maxEntries + 10) {
            record(store, actionName: "run-\(i)")
        }

        #expect(store.records.count == HistoryStore.maxEntries)
        // Recorded run-0 … run-509 (510 total); the oldest 10 are dropped, so the
        // newest survivor is run-509 and the oldest survivor is run-10.
        #expect(store.records.first?.actionName == "run-\(HistoryStore.maxEntries + 9)")
        #expect(store.records.last?.actionName == "run-10")
    }

    // MARK: - Preview transform

    @Test("storeFullText:false truncates long text and flags truncated")
    func previewTruncatesLongText() {
        let url = makeTempURL()
        defer { removeFile(url) }

        let store = HistoryStore(fileURL: url)
        let long = (1...60).map { "word\($0)" }.joined(separator: " ")
        record(store, input: long, output: long, storeFullText: false)

        let r = store.records[0]
        #expect(r.truncated)
        #expect(r.input.contains(" … "))
        #expect(r.input.count < long.count)
    }

    @Test("storeFullText:false truncates long whitespace-free text by char cap")
    func previewTruncatesWhitespaceFreeText() {
        let url = makeTempURL()
        defer { removeFile(url) }

        let store = HistoryStore(fileURL: url)
        // A single long run with no whitespace (e.g. CJK / minified JSON / token):
        // the word-count rule alone (≤24 words) would store it in full.
        let blob = String(repeating: "字", count: 600)
        record(store, input: blob, output: blob, storeFullText: false)

        let r = store.records[0]
        #expect(r.truncated)
        #expect(r.input.count < blob.count)
        #expect(r.input.contains(" … "))
    }

    @Test("storeFullText:false keeps short text intact, truncated false")
    func previewKeepsShortText() {
        let url = makeTempURL()
        defer { removeFile(url) }

        let store = HistoryStore(fileURL: url)
        record(store, input: "short input", output: "short output", storeFullText: false)

        let r = store.records[0]
        #expect(!r.truncated)
        #expect(r.input == "short input")
        #expect(r.output == "short output")
    }

    // MARK: - Delete + clear

    @Test("delete removes one record and persists")
    func deleteRemovesOne() {
        let url = makeTempURL()
        defer { removeFile(url) }

        let store = HistoryStore(fileURL: url)
        record(store, actionName: "Keep")
        record(store, actionName: "Drop")
        let dropID = store.records.first { $0.actionName == "Drop" }!.id

        store.delete(id: dropID)
        #expect(store.records.count == 1)
        #expect(store.records[0].actionName == "Keep")

        let reloaded = HistoryStore(fileURL: url)
        #expect(reloaded.records.count == 1)
        #expect(reloaded.records[0].actionName == "Keep")
    }

    @Test("clearAll empties and persists")
    func clearAllEmpties() {
        let url = makeTempURL()
        defer { removeFile(url) }

        let store = HistoryStore(fileURL: url)
        record(store)
        record(store)
        store.clearAll()
        #expect(store.records.isEmpty)

        let reloaded = HistoryStore(fileURL: url)
        #expect(reloaded.records.isEmpty)
    }

    // MARK: - Failure recording

    @Test("failure caps error message to 500 chars")
    func failureCapsError() {
        let url = makeTempURL()
        defer { removeFile(url) }

        let store = HistoryStore(fileURL: url)
        let bigError = String(repeating: "x", count: 1000)
        record(store, output: "", success: false, errorMessage: bigError)

        let r = store.records[0]
        #expect(!r.success)
        #expect(r.errorMessage?.count == 500)
    }

    // MARK: - Corrupt file tolerance

    @Test("corrupt file content loads as empty without crashing")
    func corruptFileLoadsEmpty() {
        let url = makeTempURL()
        defer { removeFile(url) }

        // Write garbage bytes where valid JSON would be.
        try? Data("not json at all {{{".utf8).write(to: url)

        let store = HistoryStore(fileURL: url)
        #expect(store.records.isEmpty)
    }
}
