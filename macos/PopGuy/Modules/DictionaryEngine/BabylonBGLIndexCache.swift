// BabylonBGLIndexCache.swift
// PopGuy — DictionaryEngine
//
// Per-dictionary on-disk SQLite index for user-loaded Babylon .bgl files.

import Foundation
import SQLite3

// MARK: - BabylonBGLSourceFileSignature

/// Identity of a .bgl source file (path, modification time, size). An index is
/// only valid while the signature it was built from still matches the file.
nonisolated struct BabylonBGLSourceFileSignature: Sendable, Codable, Equatable {
    let filePath: String
    let modificationTime: TimeInterval?
    let fileSize: Int?
}

// MARK: - SQLite binding constants

nonisolated private enum BabylonSQLite {
    /// Tells SQLite to copy bound text before the call returns.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

// MARK: - BabylonBGLIndexCache

/// Actor-owned store of one SQLite index per Babylon dictionary under
/// Application Support. Nothing is kept in memory unless the index cannot be
/// written (see `unwrittenIndexes`): every lookup opens the index
/// read-only, runs one indexed query and closes it. A missing or stale index is
/// built from a legacy .bglindex property list when one is still valid, otherwise
/// by parsing the .bgl file.
actor BabylonBGLIndexCache {
    typealias IndexParser = @Sendable (URL, BabylonDictionary) throws -> BabylonBGLIndex

    static let shared = BabylonBGLIndexCache()

    /// Bump whenever the schema or `BabylonBGLIndex.normalizedTerm` changes.
    private static let schemaVersion = 1

    /// Version of the legacy property-list index that can be converted.
    private static let legacyVersion = 2

    /// Legacy property-list index written by earlier versions. Its persisted term
    /// index is intentionally not decoded: terms are recomputed with the pinned locale.
    nonisolated struct LegacyPersistedIndex: Sendable, Codable {
        let version: Int
        let dictionaryID: UUID
        let signature: BabylonBGLSourceFileSignature
        let entries: [BabylonBGLEntry]
    }

    /// Outcome of a build. When the index could not be written, the source index
    /// is handed back so the current call can still be answered from it.
    private enum BuildResult {
        case written(entryCount: Int)
        case writeFailed(BabylonBGLIndex, any Error)
    }

    private let cacheDirectory: URL
    private let parser: IndexParser

    /// Parsed index of a source whose SQLite index could not be written.
    private struct UnwrittenIndex {
        let signature: BabylonBGLSourceFileSignature
        let index: BabylonBGLIndex
    }

    /// Kept only when the index cannot be written, so lookups keep working without
    /// re-parsing an unchanged source. Dropped when the source changes, a build
    /// succeeds or the dictionary is removed.
    private var unwrittenIndexes: [UUID: UnwrittenIndex] = [:]

    init(
        cacheDirectory: URL? = nil,
        parser: @escaping IndexParser = { url, dictionary in
            try BabylonBGLParser().parseFile(url: url, dictionary: dictionary)
        }
    ) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
        self.parser = parser
    }

    // MARK: Public API

    /// Entries whose headword or alternates match `term`. Builds the index first
    /// when it is missing or stale. Returned entries carry no alternates.
    func lookup(term: String, in dictionary: BabylonDictionary) async throws -> [BabylonBGLEntry] {
        let signature = try Self.sourceFileSignature(for: dictionary)
        let normalized = BabylonBGLIndex.normalizedTerm(term)

        if let entries = try readEntries(matching: normalized, dictionary: dictionary, signature: signature) {
            return entries
        }
        if let index = unwrittenIndex(for: dictionary.id, signature: signature) {
            return Self.entries(matching: term, in: index)
        }
        if case .writeFailed(let index, _) = try buildIndex(for: dictionary, signature: signature) {
            return Self.entries(matching: term, in: index)
        }
        guard let entries = try readEntries(matching: normalized, dictionary: dictionary, signature: signature) else {
            throw DictionaryLookupError.decoding("Babylon index is unreadable after rebuilding it")
        }
        return entries
    }

    /// Makes sure a valid index exists for `dictionary` and returns its entry count.
    @discardableResult
    func prepareIndex(for dictionary: BabylonDictionary) async throws -> Int {
        let signature = try Self.sourceFileSignature(for: dictionary)
        if let entryCount = validEntryCount(for: dictionary, signature: signature) {
            // A valid index makes any legacy file (e.g. re-created by an older app
            // version) redundant.
            try? FileManager.default.removeItem(at: legacyFileURL(for: dictionary.id))
            return entryCount
        }
        guard unwrittenIndex(for: dictionary.id, signature: signature) == nil else {
            throw DictionaryLookupError.decoding("Babylon index could not be written for the current source file")
        }
        switch try buildIndex(for: dictionary, signature: signature) {
        case .written(let entryCount):
            return entryCount
        case .writeFailed(_, let error):
            throw error
        }
    }

    /// Deletes every index file of a dictionary, including legacy and side files.
    func remove(id: UUID) {
        unwrittenIndexes[id] = nil
        for suffix in ["sqlite", "sqlite-wal", "sqlite-shm", "sqlite.tmp", "bglindex"] {
            try? FileManager.default.removeItem(at: fileURL(for: id, suffix: suffix))
        }
    }

    // MARK: Build

    /// Parser errors are thrown; a failed index write keeps the parsed index in
    /// `unwrittenIndexes` and returns it as `.writeFailed`.
    private func buildIndex(
        for dictionary: BabylonDictionary,
        signature: BabylonBGLSourceFileSignature
    ) throws -> BuildResult {
        try autoreleasepool {
            if let legacyEntries = loadLegacyEntries(for: dictionary, signature: signature) {
                do {
                    try writeIndex(entries: legacyEntries, dictionary: dictionary, signature: signature)
                } catch {
                    let index = BabylonBGLIndex(dictionary: dictionary, entries: legacyEntries)
                    unwrittenIndexes[dictionary.id] = UnwrittenIndex(signature: signature, index: index)
                    return .writeFailed(index, error)
                }
                unwrittenIndexes[dictionary.id] = nil
                try? FileManager.default.removeItem(at: legacyFileURL(for: dictionary.id))
                return .written(entryCount: legacyEntries.count)
            }

            let parsed = try parser(URL(fileURLWithPath: dictionary.filePath), dictionary)
            do {
                try writeIndex(entries: parsed.entries, dictionary: dictionary, signature: signature)
            } catch {
                unwrittenIndexes[dictionary.id] = UnwrittenIndex(signature: signature, index: parsed)
                return .writeFailed(parsed, error)
            }
            unwrittenIndexes[dictionary.id] = nil
            return .written(entryCount: parsed.entries.count)
        }
    }

    /// Entries of a legacy property-list index that still matches the source file.
    /// A stale or unreadable legacy file is deleted.
    private func loadLegacyEntries(
        for dictionary: BabylonDictionary,
        signature: BabylonBGLSourceFileSignature
    ) -> [BabylonBGLEntry]? {
        let legacyURL = legacyFileURL(for: dictionary.id)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return nil }

        guard let data = try? Data(contentsOf: legacyURL, options: .mappedIfSafe),
              let payload = try? PropertyListDecoder().decode(LegacyPersistedIndex.self, from: data),
              payload.version == Self.legacyVersion,
              payload.dictionaryID == dictionary.id,
              payload.signature == signature else {
            try? FileManager.default.removeItem(at: legacyURL)
            return nil
        }
        return payload.entries
    }

    /// Writes the index to a temporary file and moves it into place, so a crash
    /// never leaves a half-built index behind.
    private func writeIndex(
        entries: [BabylonBGLEntry],
        dictionary: BabylonDictionary,
        signature: BabylonBGLSourceFileSignature
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let temporaryURL = fileURL(for: dictionary.id, suffix: "sqlite.tmp")
        try? fileManager.removeItem(at: temporaryURL)

        do {
            try writeDatabase(at: temporaryURL, entries: entries, dictionary: dictionary, signature: signature)
            for suffix in ["sqlite", "sqlite-wal", "sqlite-shm"] {
                try? fileManager.removeItem(at: fileURL(for: dictionary.id, suffix: suffix))
            }
            try fileManager.moveItem(at: temporaryURL, to: indexFileURL(for: dictionary.id))
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func writeDatabase(
        at url: URL,
        entries: [BabylonBGLEntry],
        dictionary: BabylonDictionary,
        signature: BabylonBGLSourceFileSignature
    ) throws {
        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openCode == SQLITE_OK, let db = handle else {
            let error = Self.sqliteError("Could not create Babylon index", db: handle, code: openCode)
            sqlite3_close(handle)
            throw error
        }

        do {
            try populate(db, entries: entries, dictionary: dictionary, signature: signature)
        } catch {
            sqlite3_close(db)
            throw error
        }

        let closeCode = sqlite3_close(db)
        guard closeCode == SQLITE_OK else {
            throw Self.sqliteError("Could not close Babylon index", db: nil, code: closeCode)
        }
    }

    private func populate(
        _ db: OpaquePointer,
        entries: [BabylonBGLEntry],
        dictionary: BabylonDictionary,
        signature: BabylonBGLSourceFileSignature
    ) throws {
        try Self.execute("""
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            CREATE TABLE entries(id INTEGER PRIMARY KEY, headword TEXT NOT NULL, definition TEXT NOT NULL);
            CREATE TABLE terms(term TEXT NOT NULL, entry_id INTEGER NOT NULL);
            CREATE TABLE meta(
                schema_version INTEGER NOT NULL,
                dictionary_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                mtime REAL,
                size INTEGER,
                entry_count INTEGER NOT NULL
            );
            BEGIN;
            """, in: db, context: "Could not set up Babylon index")

        try insertEntries(entries, into: db)

        try Self.execute("""
            COMMIT;
            CREATE INDEX terms_term ON terms(term);
            """, in: db, context: "Could not index Babylon terms")

        // The meta row is written last: an index without it is never treated as valid.
        try insertMeta(into: db, entryCount: entries.count, dictionary: dictionary, signature: signature)
    }

    private func insertEntries(_ entries: [BabylonBGLEntry], into db: OpaquePointer) throws {
        let entryStatement = try Self.prepare(
            "INSERT INTO entries(id, headword, definition) VALUES (?, ?, ?)",
            in: db
        )
        defer { sqlite3_finalize(entryStatement) }
        let termStatement = try Self.prepare(
            "INSERT INTO terms(term, entry_id) VALUES (?, ?)",
            in: db
        )
        defer { sqlite3_finalize(termStatement) }

        let context = "Could not write Babylon entry"
        for (offset, entry) in entries.enumerated() {
            let entryID = sqlite3_int64(offset + 1)

            try Self.check(sqlite3_reset(entryStatement), db: db, context: context)
            try Self.check(sqlite3_bind_int64(entryStatement, 1, entryID), db: db, context: context)
            try Self.bindText(entry.headword, to: entryStatement, at: 2, db: db, context: context)
            try Self.bindText(entry.definition, to: entryStatement, at: 3, db: db, context: context)
            try Self.check(sqlite3_step(entryStatement), expected: SQLITE_DONE, db: db, context: context)

            for term in BabylonBGLIndex.lookupTerms(for: entry) {
                try Self.check(sqlite3_reset(termStatement), db: db, context: context)
                try Self.bindText(term, to: termStatement, at: 1, db: db, context: context)
                try Self.check(sqlite3_bind_int64(termStatement, 2, entryID), db: db, context: context)
                try Self.check(sqlite3_step(termStatement), expected: SQLITE_DONE, db: db, context: context)
            }
        }
    }

    private func insertMeta(
        into db: OpaquePointer,
        entryCount: Int,
        dictionary: BabylonDictionary,
        signature: BabylonBGLSourceFileSignature
    ) throws {
        let statement = try Self.prepare(
            """
            INSERT INTO meta(schema_version, dictionary_id, file_path, mtime, size, entry_count)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            in: db
        )
        defer { sqlite3_finalize(statement) }

        let context = "Could not write Babylon index metadata"
        try Self.check(sqlite3_bind_int64(statement, 1, sqlite3_int64(Self.schemaVersion)), db: db, context: context)
        try Self.bindText(dictionary.id.uuidString, to: statement, at: 2, db: db, context: context)
        try Self.bindText(signature.filePath, to: statement, at: 3, db: db, context: context)
        if let modificationTime = signature.modificationTime {
            try Self.check(sqlite3_bind_double(statement, 4, modificationTime), db: db, context: context)
        } else {
            try Self.check(sqlite3_bind_null(statement, 4), db: db, context: context)
        }
        if let fileSize = signature.fileSize {
            try Self.check(sqlite3_bind_int64(statement, 5, sqlite3_int64(fileSize)), db: db, context: context)
        } else {
            try Self.check(sqlite3_bind_null(statement, 5), db: db, context: context)
        }
        try Self.check(sqlite3_bind_int64(statement, 6, sqlite3_int64(entryCount)), db: db, context: context)
        try Self.check(sqlite3_step(statement), expected: SQLITE_DONE, db: db, context: context)
    }

    // MARK: Read

    /// The in-memory index kept after a failed write, while its source is unchanged.
    /// A stale one is dropped.
    private func unwrittenIndex(for id: UUID, signature: BabylonBGLSourceFileSignature) -> BabylonBGLIndex? {
        guard let unwritten = unwrittenIndexes[id] else { return nil }
        guard unwritten.signature == signature else {
            unwrittenIndexes[id] = nil
            return nil
        }
        return unwritten.index
    }

    /// Matches from an in-memory index, without alternates like the SQLite path.
    private static func entries(matching term: String, in index: BabylonBGLIndex) -> [BabylonBGLEntry] {
        index.lookup(term: term).map {
            BabylonBGLEntry(headword: $0.headword, definition: $0.definition, alternates: [])
        }
    }

    /// Entry count of the on-disk index, or nil when it is missing, unreadable or stale.
    private func validEntryCount(
        for dictionary: BabylonDictionary,
        signature: BabylonBGLSourceFileSignature
    ) -> Int? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(indexFileURL(for: dictionary.id).path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { return nil }
        return validEntryCount(in: db, dictionary: dictionary, signature: signature)
    }

    /// Matching entries, or nil when the index is missing, unreadable or stale.
    /// SQLite failures after the index was validated are thrown.
    private func readEntries(
        matching term: String,
        dictionary: BabylonDictionary,
        signature: BabylonBGLSourceFileSignature
    ) throws -> [BabylonBGLEntry]? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(indexFileURL(for: dictionary.id).path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle,
              validEntryCount(in: db, dictionary: dictionary, signature: signature) != nil else { return nil }
        return try queryEntries(matching: term, in: db)
    }

    private func validEntryCount(
        in db: OpaquePointer,
        dictionary: BabylonDictionary,
        signature: BabylonBGLSourceFileSignature
    ) -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT schema_version, dictionary_id, file_path, mtime, size, entry_count FROM meta LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let storedSignature = BabylonBGLSourceFileSignature(
            filePath: Self.columnText(statement, 2),
            modificationTime: sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 3),
            fileSize: sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int64(statement, 4))
        )
        guard Int(sqlite3_column_int64(statement, 0)) == Self.schemaVersion,
              Self.columnText(statement, 1) == dictionary.id.uuidString,
              storedSignature == signature else { return nil }
        return Int(sqlite3_column_int64(statement, 5))
    }

    private func queryEntries(matching term: String, in db: OpaquePointer) throws -> [BabylonBGLEntry] {
        let statement = try Self.prepare(
            """
            SELECT e.headword, e.definition FROM terms t
            JOIN entries e ON e.id = t.entry_id
            WHERE t.term = ? ORDER BY e.id
            """,
            in: db
        )
        defer { sqlite3_finalize(statement) }

        let context = "Could not read Babylon index"
        try Self.bindText(term, to: statement, at: 1, db: db, context: context)

        var entries: [BabylonBGLEntry] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            try Self.check(code, expected: SQLITE_ROW, db: db, context: context)
            entries.append(BabylonBGLEntry(
                headword: Self.columnText(statement, 0),
                definition: Self.columnText(statement, 1),
                alternates: []
            ))
        }
        return entries
    }

    // MARK: SQLite helpers

    private static func execute(_ sql: String, in db: OpaquePointer, context: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil), db: db, context: context)
    }

    private static func prepare(_ sql: String, in db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw sqliteError("Could not prepare Babylon index statement", db: db, code: code)
        }
        return statement
    }

    private static func bindText(
        _ text: String,
        to statement: OpaquePointer,
        at index: Int32,
        db: OpaquePointer,
        context: String
    ) throws {
        // Explicit byte length keeps any embedded NUL characters.
        let code = text.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, Int32(text.utf8.count), BabylonSQLite.transient)
        }
        try check(code, db: db, context: context)
    }

    private static func columnText(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private static func check(
        _ code: Int32,
        expected: Int32 = SQLITE_OK,
        db: OpaquePointer,
        context: String
    ) throws {
        guard code == expected else { throw sqliteError(context, db: db, code: code) }
    }

    private static func sqliteError(_ context: String, db: OpaquePointer?, code: Int32) -> DictionaryLookupError {
        let message: String
        if let db, let pointer = sqlite3_errmsg(db) {
            message = String(cString: pointer)
        } else {
            message = String(cString: sqlite3_errstr(code))
        }
        return .decoding("\(context): \(message)")
    }

    // MARK: Files

    private func indexFileURL(for id: UUID) -> URL {
        fileURL(for: id, suffix: "sqlite")
    }

    private func legacyFileURL(for id: UUID) -> URL {
        fileURL(for: id, suffix: "bglindex")
    }

    private func fileURL(for id: UUID, suffix: String) -> URL {
        cacheDirectory.appendingPathComponent("\(id.uuidString).\(suffix)", isDirectory: false)
    }

    private static func sourceFileSignature(for dictionary: BabylonDictionary) throws -> BabylonBGLSourceFileSignature {
        let attributes = try FileManager.default.attributesOfItem(atPath: dictionary.filePath)
        let modificationDate = attributes[.modificationDate] as? Date
        let fileSize = (attributes[.size] as? NSNumber)?.intValue
        return BabylonBGLSourceFileSignature(
            filePath: dictionary.filePath,
            modificationTime: modificationDate?.timeIntervalSinceReferenceDate,
            fileSize: fileSize
        )
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PopGuy", isDirectory: true)
            .appendingPathComponent("BabylonBGLIndexes", isDirectory: true)
    }
}
