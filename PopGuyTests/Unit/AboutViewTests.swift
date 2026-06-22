// AboutViewTests.swift
// PopGuyTests
//
// Unit tests for AboutView.makeVersionLine(version:build:releaseDate:).

import Foundation
import Testing
@testable import PopGuy

@Suite("AboutView.makeVersionLine")
struct AboutViewTests {

    @Test("version only — no build or date")
    func versionOnly() {
        let result = AboutView.makeVersionLine(version: "1.0", build: nil, releaseDate: nil)
        #expect(result == "v1.0")
    }

    @Test("version + build")
    func versionAndBuild() {
        let result = AboutView.makeVersionLine(version: "1.0", build: "42", releaseDate: nil)
        #expect(result == "v1.0 (42)")
    }

    @Test("version + release date")
    func versionAndReleaseDate() {
        let result = AboutView.makeVersionLine(version: "1.0", build: nil, releaseDate: "2026-06-22")
        #expect(result == "v1.0 · 2026-06-22")
    }

    @Test("version + build + release date")
    func allPresent() {
        let result = AboutView.makeVersionLine(version: "1.2.3", build: "99", releaseDate: "2026-06-22")
        #expect(result == "v1.2.3 (99) · 2026-06-22")
    }

    @Test("empty build string is not appended")
    func emptyBuildIsIgnored() {
        let result = AboutView.makeVersionLine(version: "1.0", build: "", releaseDate: nil)
        #expect(result == "v1.0")
    }

    @Test("empty release date string is not appended")
    func emptyReleaseDateIsIgnored() {
        let result = AboutView.makeVersionLine(version: "1.0", build: nil, releaseDate: "")
        #expect(result == "v1.0")
    }
}
