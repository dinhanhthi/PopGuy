// UpdaterVersionSanitizerTests.swift
// PopGuyTests
//
// Tests for UpdaterController.sanitizedVersion — the sanitizer that cleans an
// appcast-supplied (untrusted) version string before it is surfaced in the
// menubar / Settings UI. Verifies the ASCII allow-list (blocking homograph/bidi
// characters), whitespace trimming, empty→nil handling, and the 32-char cap.

import Testing
@testable import PopGuy

struct UpdaterVersionSanitizerTests {

    @Test func nilInputReturnsNil() {
        #expect(UpdaterController.sanitizedVersion(nil) == nil)
    }

    @Test func emptyStringReturnsNil() {
        #expect(UpdaterController.sanitizedVersion("") == nil)
    }

    @Test func whitespaceOnlyReturnsNil() {
        #expect(UpdaterController.sanitizedVersion("   ") == nil)
    }

    @Test func plainVersionPassesThrough() {
        #expect(UpdaterController.sanitizedVersion("1.2.3") == "1.2.3")
    }

    @Test func prereleaseAndBuildMetadataPreserved() {
        #expect(UpdaterController.sanitizedVersion("1.2.3-beta.1+build.456") == "1.2.3-beta.1+build.456")
    }

    @Test func homographCharactersAreStripped() {
        // "1.0а" with a Cyrillic 'а' (U+0430) — the non-ASCII letter is removed.
        let result = UpdaterController.sanitizedVersion("1.0\u{0430}")
        #expect(result == "1.0")
    }

    @Test func bidiAndControlCharactersAreStripped() {
        // Right-to-left override (U+202E) and a newline are not in the allow-list.
        let result = UpdaterController.sanitizedVersion("1.\u{202E}0\n")
        #expect(result == "1.0")
    }

    @Test func disallowedPunctuationIsStripped() {
        #expect(UpdaterController.sanitizedVersion("v1.0<script>") == "v1.0script")
    }

    @Test func resultIsCappedAt32Characters() {
        let long = String(repeating: "1", count: 50)
        let result = UpdaterController.sanitizedVersion(long)
        #expect(result?.count == 32)
    }

    @Test func leadingAndTrailingWhitespaceTrimmed() {
        #expect(UpdaterController.sanitizedVersion("  1.2.3  ") == "1.2.3")
    }
}
