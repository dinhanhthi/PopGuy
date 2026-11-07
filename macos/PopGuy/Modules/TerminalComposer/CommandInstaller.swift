// CommandInstaller.swift
//
// Installs and removes the `popguy-edit` command: a symlink in the user's bin dir
// (production: ~/.local/bin) to the CLI embedded in the app bundle
// (PopGuy.app/Contents/Helpers/popguy-edit).
//
// Safety rule: only our own symlink is ever replaced or deleted, i.e. a symlink whose
// destination is a popguy-edit inside a PopGuy.app (this one or an older copy, even
// dangling). Anything else at that path (a regular file, a directory, a symlink to
// something else) is reported as `.blockedByForeignFile` and never touched.
// The path itself is inspected with lstat semantics: the link is never followed.

import Foundation

nonisolated enum CommandInstallStatus: Equatable, Sendable {
    case notInstalled
    /// Our symlink, pointing at this app's helper.
    case installed
    /// Our symlink, pointing at a popguy-edit inside another PopGuy.app (e.g. an old copy).
    case pointsElsewhere(URL)
    /// Something that is not ours is at the path (or it cannot be inspected).
    case blockedByForeignFile
}

nonisolated enum CommandInstallError: Error, Equatable, Sendable {
    case blockedByForeignFile
}

// nonisolated: the app target defaults to MainActor isolation; Settings may call this
// from a background task.
nonisolated struct CommandInstaller: Sendable {
    static let commandName = "popguy-edit"
    /// Destination suffix that marks a symlink as ours. The leading "/" keeps e.g.
    /// "NotPopGuy.app" out.
    static let helperSuffix = "/PopGuy.app/Contents/Helpers/popguy-edit"

    let binDirectory: URL
    let target: URL

    var linkURL: URL { binDirectory.appendingPathComponent(Self.commandName) }

    init(binDirectory: URL, target: URL) {
        self.binDirectory = binDirectory
        self.target = target
    }

    /// Production installer: ~/.local/bin (home from the password database, never
    /// $HOME) to this app's embedded helper. Nil when the home dir cannot be found.
    static func standard() -> CommandInstaller? {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        let homeURL = URL(fileURLWithPath: String(cString: home), isDirectory: true)
        return CommandInstaller(
            binDirectory: homeURL.appendingPathComponent(".local/bin", isDirectory: true),
            target: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + commandName)
        )
    }

    var status: CommandInstallStatus {
        var info = stat()
        guard lstat(linkURL.path, &info) == 0 else {
            // Missing → not installed; any other failure (e.g. a parent is a file) → hands off.
            return errno == ENOENT ? .notInstalled : .blockedByForeignFile
        }
        guard info.st_mode & S_IFMT == S_IFLNK,
              let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
        else { return .blockedByForeignFile }

        // Relative destinations resolve against the bin dir; normalization is lexical
        // only ("." and ".."), so a dangling link still resolves.
        let destination = (raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : binDirectory.appendingPathComponent(raw)).standardized
        if destination.path == target.standardized.path { return .installed }
        if destination.path.hasSuffix(Self.helperSuffix) { return .pointsElsewhere(destination) }
        return .blockedByForeignFile
    }

    /// Creates the bin dir if needed and links the command to `target`. Replaces only
    /// our own (stale) symlink; throws and touches nothing when a foreign entry is there.
    func install() throws {
        let fm = FileManager.default
        switch status {
        case .installed:
            return
        case .blockedByForeignFile:
            throw CommandInstallError.blockedByForeignFile
        case .pointsElsewhere:
            try fm.removeItem(at: linkURL) // removes the link itself, not its destination
        case .notInstalled:
            try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        }
        // String API: writes `target.path` verbatim as the link text.
        try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target.path)
    }

    /// Deletes our symlink (this app's or an older PopGuy.app's). No-op when nothing is
    /// installed; throws and touches nothing when a foreign entry is there.
    func remove() throws {
        switch status {
        case .notInstalled:
            return
        case .blockedByForeignFile:
            throw CommandInstallError.blockedByForeignFile
        case .installed, .pointsElsewhere:
            try FileManager.default.removeItem(at: linkURL)
        }
    }
}
