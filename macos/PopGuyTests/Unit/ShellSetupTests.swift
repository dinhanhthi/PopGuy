// ShellSetupTests.swift
// PopGuyTests
//
// Tests for the Terminal Composer shell setup (the PopGuy-marked PATH/VISUAL block in the
// user's shell config). Always on a temp home dir, never the real one.
// Covers:
//   - Install keeps every other line, appends the block once; remove restores the file
//   - A missing config file (and its folders) is created; remove deletes it when only our block was left
//   - A block in the middle of an rc: install replaces it in place, remove keeps the lines around it
//   - fish: remove keeps the user's own lines in popguy.fish
//   - bash: the block goes into the first login file bash reads (only ~/.profile → ~/.profile)
//   - A symlinked rc stays a symlink; the block goes into its target
//   - A begin marker without an end marker: install and remove refuse

import Foundation
import Testing
@testable import PopGuy

@Suite("Terminal Composer shell setup")
struct ShellSetupTests {

    @Test("install appends the block once and keeps other lines; remove restores the file")
    func installTwiceThenRemove() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let setup = ShellSetup(homeDirectory: home, shellName: "zsh")
        let rc = home.appendingPathComponent(".zshrc")
        // Ends with a single newline: the blank line before the block is ours, so remove
        // gives back the exact bytes.
        let original = "export FOO=1\n# >>> conda >>>\nalias ll='ls -l'\n"
        try Data(original.utf8).write(to: rc)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rc.path)

        try setup.install()
        try setup.install()

        #expect(try String(contentsOf: rc, encoding: .utf8) == original + "\n" + ShellSetup.posixBlock + "\n")
        #expect(setup.status == .setUp(rc))
        #expect(try permissions(rc) == 0o600)

        try setup.remove()
        #expect(try Data(contentsOf: rc) == Data(original.utf8))
        #expect(setup.status == .notSetUp)
    }

    @Test("a missing config file and its folders are created, and removed again", arguments: [
        ("zsh", ".zshrc"), ("bash", ".bash_profile"), ("fish", ".config/fish/conf.d/popguy.fish"),
    ])
    func missingFileCreated(shell: String, path: String) throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let setup = ShellSetup(homeDirectory: home, shellName: shell)
        let file = home.appendingPathComponent(path)
        let block = shell == "fish" ? ShellSetup.fishBlock : ShellSetup.posixBlock
        #expect(setup.status == .notSetUp)

        try setup.install()
        #expect(try String(contentsOf: file, encoding: .utf8) == block + "\n")
        #expect(try permissions(file) & ~0o644 == 0)

        try setup.remove()
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test("a block in the middle of an rc is replaced in place; remove keeps the lines around it")
    func middleBlockReplacedAndRemoved() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let setup = ShellSetup(homeDirectory: home, shellName: "zsh")
        let rc = home.appendingPathComponent(".zshrc")
        let before = "export FOO=1\n"
        let after = "alias ll='ls -l'\n"
        let stale = "\(ShellSetup.beginMarker)\nexport VISUAL=old-editor\n\(ShellSetup.endMarker)\n"
        try Data((before + "\n" + stale + after).utf8).write(to: rc)

        try setup.install()
        #expect(try Data(contentsOf: rc) == Data((before + "\n" + ShellSetup.posixBlock + "\n" + after).utf8))

        try setup.remove()
        #expect(try Data(contentsOf: rc) == Data((before + after).utf8))
    }

    @Test("fish: remove keeps the user's own lines in popguy.fish")
    func fishRemoveKeepsUserLines() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let setup = ShellSetup(homeDirectory: home, shellName: "fish")
        let file = home.appendingPathComponent(".config/fish/conf.d/popguy.fish")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mine = "set -gx EDITOR nvim\n"
        try Data((mine + "\n" + ShellSetup.fishBlock + "\n").utf8).write(to: file)

        try setup.remove()
        #expect(try Data(contentsOf: file) == Data(mine.utf8))
    }

    @Test("bash: with only ~/.profile, the block goes there and no ~/.bash_profile is created")
    func bashUsesExistingProfile() throws {
        let fm = FileManager.default
        let home = try makeTempHome()
        defer { try? fm.removeItem(at: home) }
        let setup = ShellSetup(homeDirectory: home, shellName: "bash")
        let profile = home.appendingPathComponent(".profile")
        let original = "export A=1\n"
        try Data(original.utf8).write(to: profile)

        #expect(setup.configFile == profile)
        try setup.install()
        #expect(try String(contentsOf: profile, encoding: .utf8) == original + "\n" + ShellSetup.posixBlock + "\n")
        #expect(fm.fileExists(atPath: home.appendingPathComponent(".bash_profile").path) == false)

        try setup.remove()
        #expect(try Data(contentsOf: profile) == Data(original.utf8))
    }

    @Test("a symlinked rc stays a symlink and its target gets the block")
    func symlinkedRcKept() throws {
        let fm = FileManager.default
        let home = try makeTempHome()
        defer { try? fm.removeItem(at: home) }
        let setup = ShellSetup(homeDirectory: home, shellName: "bash")
        let target = home.appendingPathComponent("dotfiles/bash_profile")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("export A=1\n".utf8).write(to: target)
        let rc = home.appendingPathComponent(".bash_profile")
        try fm.createSymbolicLink(atPath: rc.path, withDestinationPath: "dotfiles/bash_profile")

        try setup.install()

        #expect(try fm.destinationOfSymbolicLink(atPath: rc.path) == "dotfiles/bash_profile")
        #expect(try String(contentsOf: target, encoding: .utf8) == "export A=1\n\n" + ShellSetup.posixBlock + "\n")
    }

    @Test("a begin marker without an end marker: install and remove refuse")
    func unterminatedBlockRefused() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let setup = ShellSetup(homeDirectory: home, shellName: "zsh")
        let rc = home.appendingPathComponent(".zshrc")
        let content = "export FOO=1\n\(ShellSetup.beginMarker)\nexport VISUAL=vim\nalias ll='ls -l'\n"
        try Data(content.utf8).write(to: rc)

        #expect(throws: ShellSetupError.unterminatedBlock) { try setup.remove() }
        #expect(throws: ShellSetupError.unterminatedBlock) { try setup.install() }
        #expect(try Data(contentsOf: rc) == Data(content.utf8))
    }

    // MARK: - Helpers

    private func permissions(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func makeTempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellSetupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
