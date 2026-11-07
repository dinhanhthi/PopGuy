// ShellSetup.swift
//
// Adds and removes the Terminal Composer shell lines (popguy-edit on PATH, set as
// VISUAL) in the user's shell config, between PopGuy marker comments:
//   zsh  → ~/.zshrc
//   bash → the first of ~/.bash_profile, ~/.bash_login, ~/.profile that exists (the
//          one a login shell reads; macOS terminals start login shells), else
//          ~/.bash_profile
//   fish → ~/.config/fish/conf.d/popguy.fish
// Any other shell is unsupported: Settings shows the snippets to paste by hand.
//
// Safety rules: only the marked block is ever written or deleted, every other line
// stays as it is. A begin marker without an end marker is refused, never guessed.
// Remove deletes a file only when nothing but whitespace is left in it. A symlinked
// config stays a symlink (never deleted): its target is rewritten. Writes are atomic
// and never more permissive than the file was. File contents are never logged.

import Foundation

nonisolated enum ShellSetupStatus: Equatable, Sendable {
    case notSetUp
    /// The block is in this file (the config path, not a symlink's target).
    case setUp(URL)
    /// The login shell's name, e.g. "tcsh".
    case unsupported(String)
}

nonisolated enum ShellSetupError: LocalizedError, Equatable, Sendable {
    case unsupportedShell
    /// A begin marker without an end marker after it.
    case unterminatedBlock
    /// The config is not UTF-8 text.
    case unreadable
    case symlinkLoop

    var errorDescription: String? {
        switch self {
        case .unsupportedShell: return "your shell isn't supported."
        case .unterminatedBlock: return "the file has a PopGuy start marker without an end marker. Fix it by hand."
        case .unreadable: return "the file isn't plain UTF-8 text."
        case .symlinkLoop: return "the file is a symlink loop."
        }
    }
}

/// What "Set up shell" will write, for the confirm dialog.
nonisolated struct ShellSetupPreview: Equatable, Sendable {
    let file: URL
    let displayPath: String
    let lines: String
}

// nonisolated: the app target defaults to MainActor isolation; Settings calls this
// from a background task.
nonisolated struct ShellSetup: Sendable {
    static let beginMarker = "# >>> PopGuy Terminal Composer >>>"
    static let endMarker = "# <<< PopGuy Terminal Composer <<<"
    static let posixBlock = [
        beginMarker,
        "export PATH=\"$HOME/.local/bin:$PATH\"",
        "export VISUAL=popguy-edit",
        endMarker,
    ].joined(separator: "\n")
    static let fishBlock = [
        beginMarker,
        "fish_add_path --global ~/.local/bin",
        "set -gx VISUAL popguy-edit",
        endMarker,
    ].joined(separator: "\n")

    let homeDirectory: URL
    /// The login shell's name, e.g. "zsh".
    let shellName: String

    /// The user's home and login shell from the password database (never $HOME or
    /// $SHELL). Nil when the record cannot be read.
    static func standard() -> ShellSetup? {
        guard let entry = getpwuid(getuid()),
              let home = entry.pointee.pw_dir, let shell = entry.pointee.pw_shell
        else { return nil }
        return ShellSetup(
            homeDirectory: URL(fileURLWithPath: String(cString: home), isDirectory: true),
            shellName: URL(fileURLWithPath: String(cString: shell)).lastPathComponent
        )
    }

    /// The config file for this shell; nil when the shell is unsupported.
    var configFile: URL? {
        switch shellName {
        case "zsh": return homeDirectory.appendingPathComponent(".zshrc")
        case "bash":
            // A bash login shell reads only the first of these that exists.
            let candidates = [".bash_profile", ".bash_login", ".profile"].map(homeDirectory.appendingPathComponent)
            return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
        case "fish": return homeDirectory.appendingPathComponent(".config/fish/conf.d/popguy.fish")
        default: return nil
        }
    }

    private var block: String { shellName == "fish" ? Self.fishBlock : Self.posixBlock }

    /// `url`'s path with the home folder shown as "~".
    func displayPath(_ url: URL) -> String {
        let home = homeDirectory.path.hasSuffix("/") ? homeDirectory.path : homeDirectory.path + "/"
        return url.path.hasPrefix(home) ? "~/" + url.path.dropFirst(home.count) : url.path
    }

    var preview: ShellSetupPreview? {
        configFile.map { ShellSetupPreview(file: $0, displayPath: displayPath($0), lines: block) }
    }

    var status: ShellSetupStatus {
        guard let file = configFile else { return .unsupported(shellName) }
        guard let text = try? read(file) else { return .notSetUp }
        return text.components(separatedBy: "\n").contains(where: Self.isBegin) ? .setUp(file) : .notSetUp
    }

    /// Adds the block at the end of the config (after a blank line), or replaces it in
    /// place when it is already there. Creates the file and its folders if missing.
    func install() throws {
        guard let file = configFile else { throw ShellSetupError.unsupportedShell }
        let target = try Self.resolveSymlinks(file)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: target.path)
        let text = exists ? try read(target) : ""
        var lines = text.components(separatedBy: "\n")
        let blockLines = block.components(separatedBy: "\n")

        if let range = try Self.blockRange(in: lines) {
            lines.replaceSubrange(range, with: blockLines)
            let updated = lines.joined(separator: "\n")
            if updated != text { try write(updated, to: target) }
            return
        }

        var updated = text
        if !updated.isEmpty {
            if !updated.hasSuffix("\n") { updated += "\n" }
            if !updated.hasSuffix("\n\n") { updated += "\n" }
        }
        updated += block + "\n"
        if !exists {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try write(updated, to: target)
    }

    /// Deletes the block (and the blank line before it). Deletes the file when only
    /// whitespace is left, unless it is a symlink. No-op when the block is not there.
    func remove() throws {
        guard let file = configFile else { throw ShellSetupError.unsupportedShell }
        let target = try Self.resolveSymlinks(file)
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return }
        let text = try read(target)
        var lines = text.components(separatedBy: "\n")
        guard let range = try Self.blockRange(in: lines) else { return }

        lines.removeSubrange(range)
        if range.lowerBound > 0, Self.isBlank(lines[range.lowerBound - 1]) {
            lines.remove(at: range.lowerBound - 1)
        }
        // An empty file left behind would still be read first (e.g. a ~/.bash_profile
        // hides ~/.profile). A symlink is the user's own setup: keep it.
        let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: file.path)) != nil
        if lines.allSatisfy(Self.isBlank), !isSymlink {
            try fm.removeItem(at: file)
            return
        }
        try write(lines.joined(separator: "\n"), to: target)
    }

    // MARK: - Helpers

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isBegin(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == beginMarker
    }

    /// The marked block's lines; nil when there is no begin marker.
    private static func blockRange(in lines: [String]) throws -> ClosedRange<Int>? {
        guard let begin = lines.firstIndex(where: isBegin) else { return nil }
        guard let end = lines[begin...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == endMarker
        }) else { throw ShellSetupError.unterminatedBlock }
        return begin...end
    }

    /// Follows symlinks, even a dangling one, so the write goes to the real file and
    /// the link itself is kept.
    private static func resolveSymlinks(_ url: URL) throws -> URL {
        var url = url
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
                return url
            }
            url = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        throw ShellSetupError.symlinkLoop
    }

    private func read(_ url: URL) throws -> String {
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw ShellSetupError.unreadable
        }
        return text
    }

    /// Atomic write (temp file in the same folder, then rename over `url`). The temp file
    /// is created with the original file's mode (0644 under the umask for a new file), so
    /// the content is never readable by more users than before, not even briefly.
    private func write(_ text: String, to url: URL) throws {
        var info = stat()
        let existing = stat(url.path, &info) == 0
        let mode: mode_t = existing ? info.st_mode & 0o777 : 0o644
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).popguy-\(UUID().uuidString).tmp").path

        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Self.posixError() }
        do {
            // The umask may have cleared bits: give back the original mode exactly.
            if existing, fchmod(fd, mode) != 0 { throw Self.posixError() }
            try Array(text.utf8).withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Self.posixError()
                    }
                    offset += written
                }
            }
            if fsync(fd) != 0 { throw Self.posixError() }
        } catch {
            close(fd)
            unlink(temp)
            throw error
        }
        if close(fd) != 0 || rename(temp, url.path) != 0 {
            let error = Self.posixError()
            unlink(temp)
            throw error
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
