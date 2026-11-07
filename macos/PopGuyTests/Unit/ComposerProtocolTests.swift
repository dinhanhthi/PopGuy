// ComposerProtocolTests.swift
// PopGuyTests
//
// Tests for the Terminal Composer wire protocol and file rules (app copy of
// ComposerProtocol.swift, MIRROR of macos/PopGuyEdit/ComposerProtocol.swift).
// Covers:
//   - Codec contract: golden lines for every message type, unknown type and caps rejected
//   - Security: directories, FIFOs, oversized and non-UTF-8 files are refused
//   - Trailing-newline and line-ending rule: LF and CRLF files round-trip byte-identical

import Foundation
import Testing
@testable import PopGuy

@Suite("Terminal Composer protocol and file rules")
struct ComposerProtocolTests {

    // MARK: - Codec contract

    // ASCII-only, no "/" (Swift's JSON encoder writes "\/"), shared with the Windows tests.
    private static let goldenLines: [(String, ComposerMessage)] = [
        (#"{"type":"open","text":"Hello\nworld","fileName":"COMMIT_EDITMSG","mode":"edit"}"#,
         .open(text: "Hello\nworld", fileName: "COMMIT_EDITMSG", mode: "edit")),
        (#"{"type":"done","text":"Fixed \"it\"","submit":true}"#,
         .done(text: "Fixed \"it\"", submit: true)),
        (#"{"type":"done","text":"","submit":false}"#,
         .done(text: "", submit: false)),
        (#"{"type":"cancel"}"#, .cancel),
        (#"{"type":"busy"}"#, .busy),
        (#"{"type":"error","reason":"Terminal Composer is off"}"#,
         .error(reason: "Terminal Composer is off")),
    ]

    @Test("golden lines decode, and every message round-trips as one line")
    func goldenLinesRoundTrip() throws {
        for (golden, expected) in Self.goldenLines {
            // Decoding accepts the line with or without its terminating newline.
            #expect(try ComposerMessage.decodeLine(Data(golden.utf8)) == expected)
            #expect(try ComposerMessage.decodeLine(Data((golden + "\n").utf8)) == expected)

            let line = try ComposerMessage.encodeLine(expected)
            #expect(line.last == 0x0A)
            #expect(line.dropLast().contains(0x0A) == false)
            #expect(try ComposerMessage.decodeLine(line) == expected)

            // Same wire keys and values as the golden line (key order is free).
            let encoded = try JSONSerialization.jsonObject(with: line.dropLast()) as? NSDictionary
            let reference = try JSONSerialization.jsonObject(with: Data(golden.utf8)) as? NSDictionary
            #expect(encoded != nil && encoded == reference)
        }
    }

    @Test("unknown type is rejected")
    func unknownTypeRejected() {
        #expect(throws: (any Error).self) {
            try ComposerMessage.decodeLine(Data(#"{"type":"save","text":"x"}"#.utf8))
        }
    }

    @Test("oversized line and oversized text are rejected")
    func capsEnforced() {
        let longLine = Data(repeating: 0x61, count: ComposerMessage.maxLineBytes + 1)
        #expect(throws: ComposerProtocolError.lineTooLarge) {
            try ComposerMessage.decodeLine(longLine)
        }

        let bigText = String(repeating: "a", count: ComposerMessage.maxTextBytes + 1)
        #expect(throws: ComposerProtocolError.textTooLarge) {
            try ComposerMessage.encodeLine(.done(text: bigText, submit: false))
        }
        let bigLine = Data((#"{"type":"done","submit":false,"text":""# + bigText + #""}"#).utf8)
        #expect(throws: ComposerProtocolError.textTooLarge) {
            try ComposerMessage.decodeLine(bigLine)
        }
    }

    // MARK: - File rules: security

    @Test("directories, FIFOs, oversized and non-UTF-8 files are refused")
    func nonEditableFilesRefused() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: ComposerFileError.notRegularFile) {
            try ComposerFileRules.read(path: dir.path)
        }

        // Reading a FIFO must fail at once, never block waiting for a writer.
        let fifo = dir.appendingPathComponent("pipe").path
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(throws: ComposerFileError.notRegularFile) {
            try ComposerFileRules.read(path: fifo)
        }

        let big = dir.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: ComposerFileRules.maxFileBytes + 1).write(to: big)
        #expect(throws: ComposerFileError.tooLarge) {
            try ComposerFileRules.read(path: big.path)
        }

        let binary = dir.appendingPathComponent("binary.txt")
        try Data([0x41, 0xFF, 0xFE, 0x42]).write(to: binary)
        #expect(throws: ComposerFileError.invalidUTF8) {
            try ComposerFileRules.read(path: binary.path)
        }
    }

    // MARK: - File rules: trailing newline and line endings

    @Test("LF and CRLF files round-trip with their trailing newline; missing file is empty")
    func newlineRule() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lf = dir.appendingPathComponent("lf.md")
        try Data("one\ntwo\n".utf8).write(to: lf)
        let lfInfo = try ComposerFileRules.read(path: lf.path)
        #expect(lfInfo == ComposerFileContent(text: "one\ntwo", hadTrailingNewline: true, lineEnding: .lf))
        try ComposerFileRules.write("one\nthree", to: lf.path, original: lfInfo)
        #expect(try Data(contentsOf: lf) == Data("one\nthree\n".utf8))

        let crlf = dir.appendingPathComponent("crlf.md")
        try Data("one\r\ntwo\r\n".utf8).write(to: crlf)
        let crlfInfo = try ComposerFileRules.read(path: crlf.path)
        #expect(crlfInfo == ComposerFileContent(text: "one\ntwo", hadTrailingNewline: true, lineEnding: .crlf))
        try ComposerFileRules.write("one\nthree", to: crlf.path, original: crlfInfo)
        #expect(try Data(contentsOf: crlf) == Data("one\r\nthree\r\n".utf8))

        // No trailing newline in the original: none is added on write.
        let bare = dir.appendingPathComponent("bare.md")
        try Data("one".utf8).write(to: bare)
        let bareInfo = try ComposerFileRules.read(path: bare.path)
        #expect(bareInfo.hadTrailingNewline == false)
        try ComposerFileRules.write("two", to: bare.path, original: bareInfo)
        #expect(try Data(contentsOf: bare) == Data("two".utf8))

        let missing = dir.appendingPathComponent("missing.md")
        #expect(try ComposerFileRules.read(path: missing.path)
            == ComposerFileContent(text: "", hadTrailingNewline: false, lineEnding: .lf))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerProtocolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
