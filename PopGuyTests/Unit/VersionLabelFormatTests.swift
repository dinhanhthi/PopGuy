// VersionLabelFormatTests.swift
// PopGuyTests
//
// Tests for `formatVersionLabel` — the free function that formats the footer
// version string in SettingsFooter.

import Testing
@testable import PopGuy

struct VersionLabelFormatTests {

    @Test func buildPresent() {
        #expect(formatVersionLabel(version: "1.0", build: "2") == "PopGuy v1.0 (2)")
    }

    @Test func buildNil() {
        #expect(formatVersionLabel(version: "1.0", build: nil) == "PopGuy v1.0")
    }

    @Test func buildEmpty() {
        #expect(formatVersionLabel(version: "1.0", build: "") == "PopGuy v1.0")
    }
}
