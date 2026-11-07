// CommandInstallerTests.swift
// PopGuyTests
//
// Tests for the Terminal Composer command installer (~/.local/bin/popguy-edit symlink).
// Covers:
//   - Security: a foreign file or foreign symlink is never overwritten or removed
//   - Install over our stale (dangling, relative) link replaces it
//   - Install into a missing bin dir creates it; remove deletes only our link

import Foundation
import Testing
@testable import PopGuy

@Suite("Terminal Composer command installer")
struct CommandInstallerTests {

    @Test("a foreign file or foreign symlink is never overwritten or removed")
    func foreignEntryUntouched() throws {
        let fm = FileManager.default
        // A symlink to a popguy-edit that is not inside a PopGuy.app is foreign too.
        let foreignLinks = ["/usr/bin/true", "../NotPopGuy.app/Contents/Helpers/popguy-edit"]

        for foreignLink in [nil] + foreignLinks {
            let dir = try makeTempDir()
            defer { try? fm.removeItem(at: dir) }
            let installer = makeInstaller(in: dir)
            try fm.createDirectory(at: installer.binDirectory, withIntermediateDirectories: true)
            let path = installer.linkURL.path
            if let foreignLink {
                try fm.createSymbolicLink(atPath: path, withDestinationPath: foreignLink)
            } else {
                try Data("#!/bin/sh\necho mine\n".utf8).write(to: installer.linkURL)
            }

            #expect(installer.status == .blockedByForeignFile)
            #expect(throws: (any Error).self) { try installer.install() }
            #expect(throws: (any Error).self) { try installer.remove() }

            if let foreignLink {
                #expect(try fm.destinationOfSymbolicLink(atPath: path) == foreignLink)
            } else {
                #expect(try Data(contentsOf: installer.linkURL) == Data("#!/bin/sh\necho mine\n".utf8))
            }
        }
    }

    @Test("install replaces our stale link to another PopGuy.app")
    func installOverStaleLink() throws {
        let fm = FileManager.default
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let installer = makeInstaller(in: dir)
        try fm.createDirectory(at: installer.binDirectory, withIntermediateDirectories: true)
        // Relative and dangling: Old/PopGuy.app does not exist.
        try fm.createSymbolicLink(atPath: installer.linkURL.path,
                                  withDestinationPath: "../../../Old/PopGuy.app/Contents/Helpers/popguy-edit")

        guard case .pointsElsewhere(let stale) = installer.status else {
            Issue.record("expected .pointsElsewhere, got \(installer.status)")
            return
        }
        #expect(stale.path == dir.appendingPathComponent("Old/PopGuy.app/Contents/Helpers/popguy-edit").path)

        try installer.install()
        #expect(installer.status == .installed)
        #expect(try fm.destinationOfSymbolicLink(atPath: installer.linkURL.path) == installer.target.path)
    }

    @Test("install creates a missing bin dir; remove deletes only our link")
    func installThenRemove() throws {
        let fm = FileManager.default
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let installer = makeInstaller(in: dir)
        #expect(fm.fileExists(atPath: installer.binDirectory.path) == false)
        #expect(installer.status == .notInstalled)

        try installer.install()
        #expect(installer.status == .installed)

        try installer.remove()
        #expect(installer.status == .notInstalled)
        #expect(fm.fileExists(atPath: installer.binDirectory.path))
        try installer.remove() // nothing there: no-op
    }

    // MARK: - Helpers

    private func makeInstaller(in dir: URL) -> CommandInstaller {
        CommandInstaller(
            binDirectory: dir.appendingPathComponent("home/.local/bin"),
            target: dir.appendingPathComponent("Applications/PopGuy.app/Contents/Helpers/popguy-edit")
        )
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
