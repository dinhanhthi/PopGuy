// SettingsSidebarLayoutTests.swift
// PopGuyTests
//
// Regression coverage for the Settings sidebar row density. The sidebar is a
// SwiftUI List, so keep its vertical row padding explicit instead of relying on
// AppKit's default sidebar row height.

import Foundation
import Testing

@Suite("SettingsSidebarLayout")
struct SettingsSidebarLayoutTests {

    @Test("settings sidebar rows use explicit vertical padding")
    func settingsSidebarRowsUseExplicitVerticalPadding() throws {
        let sourceURL = try repositoryRoot()
            .appendingPathComponent("PopGuy/UI/SettingsWindow/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(
            source.contains(".padding(.vertical, SettingsMetrics.sidebarItemVerticalPadding)"),
            "Expected Settings sidebar labels to add explicit vertical padding between items."
        )
    }

    @Test("settings sidebar padding follows the shared four-point scale")
    func settingsSidebarPaddingFollowsSharedScale() throws {
        let sourceURL = try repositoryRoot()
            .appendingPathComponent("PopGuy/UI/SettingsWindow/Components/SettingsCard.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(
            source.contains("static let sidebarItemVerticalPadding: CGFloat = 4"),
            "Expected Settings sidebar item vertical padding to use the shared 4pt scale."
        )
    }

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("PopGuy.xcodeproj").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        throw SettingsSidebarLayoutTestError.repositoryRootNotFound
    }
}

private enum SettingsSidebarLayoutTestError: Error {
    case repositoryRootNotFound
}
