// ComposerDraftStore.swift
// PopGuy
//
// Composer drafts: one plain UTF-8 file per draft, `<draft id>.txt`, in
// ~/Library/Application Support/PopGuy/Composer/drafts (directory 0700, files 0600,
// created with that mode so the text is never readable by others). The file's
// modification date is the draft's age. All file I/O runs on a private serial queue.
//
// Policy (applied by the owner): a session's draft is deleted once Done delivered the
// text; kept on Cancel, after an unconfirmed delivery, when the terminal session ends,
// and on app quit with changed text (`flush()`).
// Prompt text is never logged; only counts and states.

import Foundation
import os

/// Thread safety: every mutable stored property is read and written only on `queue`
/// (a private serial Dispatch queue); the public methods hop onto it. That confinement
/// is the invariant behind `@unchecked Sendable`, as in `ComposerServer`.
nonisolated final class ComposerDraftStore: @unchecked Sendable {

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PopGuy", category: "composer")
    private static let autosaveDelay: TimeInterval = 2
    private static let keepCount = 5
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private let queue = DispatchQueue(label: "PopGuy.ComposerDraftStore")
    /// nil when the home directory cannot be found (every operation is then a no-op).
    private let directory: String?
    private var pending: [UUID: (text: String, item: DispatchWorkItem)] = [:]
    private var lastSaved: [UUID: String] = [:]

    init() {
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            directory = String(cString: home) + "/Library/Application Support/PopGuy/Composer/drafts"
        } else {
            directory = nil
        }
    }

    // MARK: Public API

    /// Saves the draft about 2 s after the last call for `id` (debounced autosave).
    func scheduleSave(id: UUID, text: String) {
        queue.async { [self] in
            pending[id]?.item.cancel()
            let item = DispatchWorkItem { [self] in
                guard let entry = pending.removeValue(forKey: id) else { return }
                writeIfChanged(id: id, text: entry.text)
            }
            pending[id] = (text, item)
            queue.asyncAfter(deadline: .now() + Self.autosaveDelay, execute: item)
        }
    }

    /// Saves the draft now (replacing a pending autosave). Empty text removes the draft.
    func save(id: UUID, text: String) {
        queue.async { [self] in
            pending.removeValue(forKey: id)?.item.cancel()
            writeIfChanged(id: id, text: text)
        }
    }

    /// Writes every pending autosave before returning (app quit, window close).
    func flush() {
        queue.sync {
            let entries = pending
            pending.removeAll()
            for (id, entry) in entries {
                entry.item.cancel()
                writeIfChanged(id: id, text: entry.text)
            }
        }
    }

    /// Deletes the draft and drops its pending autosave, so it is not written again.
    func delete(id: UUID) {
        queue.async { [self] in
            pending.removeValue(forKey: id)?.item.cancel()
            lastSaved.removeValue(forKey: id)
            removeFile(id: id)
        }
    }

    /// The most recently modified draft other than `id`, for "Restore draft".
    func latestDraft(excluding id: UUID?) async -> (id: UUID, text: String)? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: latestDraftOnQueue(excluding: id))
            }
        }
    }

    /// Deletes drafts older than 7 days and all but the 5 newest. Call when a composer opens.
    func prune() {
        queue.async { [self] in
            let now = Date()
            var removed = 0
            for (index, draft) in listDrafts().enumerated()
            where index >= Self.keepCount || now.timeIntervalSince(draft.modified) > Self.maxAge {
                removeFile(id: draft.id)
                removed += 1
            }
            if removed > 0 {
                Self.log.info("Composer drafts: pruned \(removed) file(s)")
            }
        }
    }

    // MARK: Queue-confined helpers

    private func writeIfChanged(id: UUID, text: String) {
        guard lastSaved[id] != text else { return }
        if text.isEmpty {
            removeFile(id: id)
            lastSaved[id] = text
        } else if write(id: id, text: text) {
            lastSaved[id] = text
        }
    }

    private func write(id: UUID, text: String) -> Bool {
        guard let directory, Self.preparePrivateDirectory(directory) else { return false }
        let path = filePath(directory, id)
        // Created 0600; fchmod also fixes the mode of an existing file before any byte is written.
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            Self.log.error("Composer drafts: cannot open a draft file (errno \(errno))")
            return false
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              fchmod(fd, 0o600) == 0 else {
            Self.log.error("Composer drafts: a draft path is not a private file of this user")
            return false
        }
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                Self.log.error("Composer drafts: write failed (errno \(errno))")
                return false
            }
            offset += written
        }
        Self.log.debug("Composer drafts: saved \(bytes.count) bytes")
        return true
    }

    private func removeFile(id: UUID) {
        guard let directory else { return }
        unlink(filePath(directory, id))
    }

    private func latestDraftOnQueue(excluding excluded: UUID?) -> (id: UUID, text: String)? {
        guard let directory else { return nil }
        for draft in listDrafts() where draft.id != excluded {
            if let text = read(filePath(directory, draft.id)), !text.isEmpty {
                return (draft.id, text)
            }
        }
        return nil
    }

    private func read(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Drafts of this user (regular `<uuid>.txt` files), newest first.
    private func listDrafts() -> [(id: UUID, modified: Date)] {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        var drafts: [(id: UUID, modified: Date)] = []
        for name in names where name.hasSuffix(".txt") {
            guard let id = UUID(uuidString: String(name.dropLast(4))) else { continue }
            var info = stat()
            guard lstat(directory + "/" + name, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid() else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            drafts.append((id, modified))
        }
        return drafts.sorted { $0.modified > $1.modified }
    }

    private func filePath(_ directory: String, _ id: UUID) -> String {
        directory + "/" + id.uuidString + ".txt"
    }

    /// Creates `drafts` (and its `Composer` parent) if needed and makes both 0700
    /// directories owned by this user, also when they already existed.
    private static func preparePrivateDirectory(_ path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            log.error("Composer drafts: cannot create the drafts directory")
            return false
        }
        let parent = (path as NSString).deletingLastPathComponent
        for directory in [parent, path] {
            var info = stat()
            guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                  chmod(directory, 0o700) == 0 else {
                log.error("Composer drafts: the drafts directory is not a private directory of this user")
                return false
            }
        }
        return true
    }
}
