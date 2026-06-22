// HistoryStore.swift
// PopGuy — HistoryStore
//
// File-backed, capped log of completed action runs, surfaced in the History tab.
//
// Storage: a dedicated JSON file (`history.json`) under
// ~/Library/Application Support/PopGuy/ — NOT UserDefaults, since this is
// append-heavy and may hold large text, which would bloat the prefs plist.
//
// Isolation: @MainActor ObservableObject (mirrors SettingsStore). The emit
// points already run on the MainActor (inside `Task { @MainActor in ... }`),
// so recording happens with no actor hop.

import Foundation
import Combine

// MARK: - HistoryStore

/// Observable, capped, file-backed history of action runs (newest first).
@MainActor
final class HistoryStore: ObservableObject {

    /// Logged runs, newest first (index 0 = most recent).
    @Published private(set) var records: [HistoryRecord] = []

    /// Hard cap on stored records; oldest are dropped past this.
    nonisolated static let maxEntries = 500

    // MARK: - Storage

    private let fileURL: URL

    // MARK: - Init

    /// Create a HistoryStore backed by `fileURL`, or the default Application
    /// Support location when nil. The injectable URL lets tests use a temp file.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    /// `~/Library/Application Support/PopGuy/history.json`.
    private static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PopGuy", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    // MARK: - Recording

    /// Append a record for a completed run, then persist.
    ///
    /// When `storeFullText` is false, `input`/`output` are stored as previews
    /// (first/last words) and `truncated` is set true only if a transform
    /// actually shortened the text. `errorMessage` is capped to bound size.
    func record(
        actionName: String,
        providerKind: ProviderKind?,
        providerLabel: String? = nil,
        model: String,
        sourceBundleID: String?,
        sourceAppName: String?,
        durationMs: Int,
        success: Bool,
        errorMessage: String?,
        input: String,
        output: String,
        storeFullText: Bool
    ) {
        let storedInput: String
        let storedOutput: String
        let truncated: Bool
        if storeFullText {
            storedInput = input
            storedOutput = output
            truncated = false
        } else {
            storedInput = Self.preview(input)
            storedOutput = Self.preview(output)
            // Only flag truncation when a transform actually shortened something.
            truncated = (storedInput != input) || (storedOutput != output)
        }

        // Cap the error message to bound record size (key-leak risk is low, but
        // a runaway error body shouldn't bloat the file).
        let cappedError = errorMessage.map { String($0.prefix(500)) }

        let record = HistoryRecord(
            id: UUID(),
            timestamp: Date(),
            actionName: actionName,
            providerKind: providerKind,
            providerLabel: providerLabel,
            model: model,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            durationMs: durationMs,
            success: success,
            errorMessage: cappedError,
            input: storedInput,
            output: storedOutput,
            truncated: truncated
        )

        records.insert(record, at: 0)
        if records.count > Self.maxEntries {
            records.removeLast(records.count - Self.maxEntries)
        }
        save()
    }

    /// Remove the record with the given id, then persist.
    func delete(id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    /// Empty the history, then persist.
    func clearAll() {
        records.removeAll()
        save()
    }

    // MARK: - Preview transform

    /// Upper bound on a stored preview's character count. Bounds whitespace-free
    /// blobs (CJK, minified JSON, URLs, tokens) that the word-count rule alone
    /// would let through at full length when full-text storage is off.
    private static let previewMaxChars = 240

    /// Shorten `text` to a first/last preview when it's long; pass short text
    /// through unchanged. Applies a word-count rule first, then a hard character
    /// cap so the "preview only" promise holds even for text with few or no
    /// whitespace runs. A small pure helper owned by the store so the truncation
    /// is a write-time transform, not a render-time one.
    private static func preview(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        let wordPreview: String
        if words.count > 24 {
            let n = 12
            let head = words.prefix(n).joined(separator: " ")
            let tail = words.suffix(n).joined(separator: " ")
            wordPreview = head + " … " + tail
        } else {
            wordPreview = text
        }
        return capCharacters(wordPreview)
    }

    /// First/last-half character cap with an ellipsis, applied to text that
    /// exceeds `previewMaxChars`. Short text is returned unchanged.
    private static func capCharacters(_ text: String) -> String {
        guard text.count > previewMaxChars else { return text }
        let half = previewMaxChars / 2
        let head = text.prefix(half)
        let tail = text.suffix(half)
        return head + " … " + tail
    }

    // MARK: - Persistence

    /// Read records from disk. Missing file OR corrupt JSON → empty list; never
    /// throws on load (mirrors SettingsStore's `try?` tolerance).
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            records = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([HistoryRecord].self, from: data)) ?? []
    }

    /// Write records to disk, creating the parent directory if needed. Best-
    /// effort: a write failure is swallowed (history is not critical state).
    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
